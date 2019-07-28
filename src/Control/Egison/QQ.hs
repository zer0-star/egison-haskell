{-# LANGUAGE TemplateHaskell  #-}
{-# LANGUAGE TupleSections   #-}

module Control.Egison.QQ (
  mc
  ) where

import           Control.Egison.Core
import           Data.List
import           Data.Map            (Map)
import           Data.Maybe          (fromMaybe)
import           Data.Strings
import           Language.Haskell.Meta
import           Language.Haskell.TH        hiding (match)
import           Language.Haskell.TH.Quote
import           Language.Haskell.TH.Syntax
import           Text.Regex
import           Unsafe.Coerce
import           Useful.Dictionary

mc :: QuasiQuoter
mc = QuasiQuoter { quoteExp = \s -> do
                      let (pat, exp) = strSplit "=>" s
                      e1 <- case parseExp (changeValuePat (changePatVar pat)) of
                              Left _ -> fail "Could not parse pattern expression."
                              Right exp -> return exp
                      e2 <- case parseExp exp of
                                 Left _ -> fail "Could not parse expression."
                                 Right exp -> return exp
                      mcChange e1 e2
                  , quotePat = undefined
                  , quoteType = undefined
                  , quoteDec = undefined }

changePatVar :: String -> String
changePatVar pat = subRegex (mkRegex "\\$([a-zA-Z0-9]+)") pat "(PatVar \"\\1\")"

changeValuePat :: String -> String
changeValuePat pat = subRegex (mkRegex "\\#(\\([^)]+\\)|\\[[^)]+\\]|[a-zA-Z0-9]+)") pat "(ValuePat \\1)"

mcChange :: Exp -> Exp -> Q Exp
mcChange pat expr = do
  let (vars, xs) = extractPatVars [pat] []
  [| ($(fst <$> changePat pat (map (`take` vars) xs)), $(changeExp vars expr)) |]

-- extract patvars from pattern
extractPatVars :: [Exp] -> [String] -> ([String], [Int])
extractPatVars [] vars = (vars, [])
extractPatVars (ParensE x:xs) vars = extractPatVars (x:xs) vars
extractPatVars (AppE (ConE name) p:xs) vars
  | nameBase name == "PatVar" = case p of (LitE (StringL s)) -> extractPatVars xs (vars ++ [s])
  | nameBase name == "ValuePat" = let (vs, ns) = extractPatVars xs vars in (vs, length vars:ns)
  | nameBase name == "NotPat" = extractPatVars (p:xs) vars
  | nameBase name == "LaterPat" =
      let (vs1, ns1) = extractPatVars xs vars in
      let (vs2, ns2) = extractPatVars [p] vs1 in (vs2, ns2 ++ ns1)
  | otherwise = extractPatVars (p:xs) vars
extractPatVars (AppE (AppE (ConE name) p1) p2:xs) vars = extractPatVars (p1:p2:xs) vars
extractPatVars (AppE (VarE _) p:xs) vars = extractPatVars (p:xs) vars
extractPatVars (InfixE (Just (ConE name)) (VarE op) (Just p):xs) vars = extractPatVars (AppE (ConE name) p:xs) vars
extractPatVars (UInfixE (ConE name) (VarE op) y:xs) vs = extractPatVars (AppE (ConE name) y:xs) vs
extractPatVars (UInfixE (UInfixE x (VarE op) y) z w:xs) vs = extractPatVars (AppE x (UInfixE y z w):xs) vs
extractPatVars (SigE x typ:xs) vs = extractPatVars (x:xs) vs
extractPatVars (ListE ls:xs) vs = extractPatVars (ls ++ xs) vs
extractPatVars (_:xs) vars = extractPatVars xs vars

-- change ValuePat e to \[Result x] -> let x' = unsafeCoerce x in e
changePat :: Exp -> [[String]] -> Q (Exp, [[String]])
changePat e@(AppE (ConE name) p) vs
  | nameBase name == "ValuePat" = do
      let (vars:varss) = vs
      (, varss) <$> appE (conE 'ValuePat) (changeExp vars p)
  | otherwise = do
      (e', vs') <- changePat p vs
      (, vs') <$> appE (conE name) (return e')
changePat (AppE e1 e2) vs = do
  (e1', vs') <- changePat e1 vs
  (e2', vs'') <- changePat e2 vs'
  (, vs'') <$> appE (return e1') (return e2')
changePat (InfixE (Just (ConE name)) (VarE op) (Just p)) vs = changePat (AppE (ConE name) p) vs
changePat (UInfixE (ConE name) (VarE op) p) vs = changePat (AppE (ConE name) p) vs
changePat (UInfixE (UInfixE x (VarE op) y) z w) vs = changePat (AppE x (UInfixE y z w)) vs
changePat (ParensE x) vs = changePat x vs
changePat (SigE x typ) vs = changePat x vs
changePat (ListE (x:xs)) vs = do
  (x', vs') <- changePat x vs
  (ListE xs', vs'') <- changePat (ListE xs) vs'
  return (ListE (x':xs'), vs'')
changePat e vs = return (e, vs)

-- change e to \[Result x] -> let x' = unsafeCoerce x in e
changeExp :: [String] -> Exp -> Q Exp
changeExp vars expr = do
  vars' <- mapM newName vars
  vars'' <- mapM (\s -> newName $ s ++ "'") vars
  lamE [listP $ map (\x -> conP 'Result [varP x]) vars']
    $ foldr (\(x, x') acc -> letE [valD (varP x') (normalB (appE (varE 'unsafeCoerce) (varE x))) []] acc) (return $ changeExp' (dict $ zip vars vars'') expr) $ zip vars' vars''

-- replace x in e to x'
changeExp' :: Map String Name -> Exp -> Exp
changeExp' dct (VarE name) = VarE $ changeName dct name
changeExp' dct (AppE e1 e2) = AppE (changeExp' dct e1) (changeExp' dct e2)
changeExp' dct (InfixE me1 e me2) = InfixE (fmap (changeExp' dct) me1) e (fmap (changeExp' dct) me2)
changeExp' dct (UInfixE e1 e2 e3) = UInfixE (changeExp' dct e1) (changeExp' dct e2) (changeExp' dct e3)
changeExp' dct (ParensE e) = ParensE (changeExp' dct e)
changeExp' dct (LamE pats e) = LamE pats (changeExp' dct e)
changeExp' dct (TupE es) = TupE $ map (changeExp' dct) es
changeExp' dct (UnboxedTupE es) = UnboxedTupE $ map (changeExp' dct) es
changeExp' dct (CondE e1 e2 e3) = CondE (changeExp' dct e1) (changeExp' dct e2) (changeExp' dct e3)
changeExp' dct (MultiIfE es) = MultiIfE $ map (\(g, e) -> (g, changeExp' dct e)) es
changeExp' dct (LetE ds e) = LetE ds $ changeExp' dct e
changeExp' dct (CaseE e ms) = CaseE (changeExp' dct e) ms
changeExp' dct (ListE es) = ListE $ map (changeExp' dct) es
changeExp' dct (SigE e t) = SigE (changeExp' dct e) t
changeExp' dct (RecConE name fs) = RecConE (changeName dct name) fs
changeExp' dct (RecUpdE e fs) = RecUpdE (changeExp' dct e) fs
changeExp' dct (StaticE e) = StaticE $ changeExp' dct e
changeExp' dct (UnboundVarE name) = VarE $ changeName dct name
changeExp' _ e = e

changeName :: Map String Name -> Name -> Name
changeName dct name = fromMaybe name $ nameBase name #! dct