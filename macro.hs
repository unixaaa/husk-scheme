{-
 - husk scheme
 - Macro
 -
 - This file contains code for hygenic macros 
 -
 - @author Justin Ethier
 -
 - -}
module Scheme.Macro where
import Scheme.Types
import Scheme.Variables
import Control.Monad
import Control.Monad.Error

-- Nice FAQ regarding macro's, points out some of the limitations of current implementation
-- http://community.schemewiki.org/?scheme-faq-macros

-- Search for macro's in the AST, and transform any that are found.
-- There is also a special case (define-syntax) that loads new rules.
macroEval :: Env -> LispVal -> IOThrowsError LispVal
macroEval env (List [Atom "define-syntax", Atom keyword, syntaxRules@(List (Atom "syntax-rules" : (List identifiers : rules)))]) = do
  -- TODO: there really ought to be some error checking of the syntax rules, since they could be malformed...
  --       As it stands now, there is no checking until the code attempts to perform a macro transformation.
  defineNamespacedVar env macroNamespace keyword syntaxRules
  return $ Nil "" -- Sentinal value
macroEval env lisp@(List (x@(List _) : xs)) = do
  first <- macroEval env x
  rest <- mapM (macroEval env) xs
  return $ List $ first : rest
-- TODO: equivalent matches/transforms for vectors
--       what about dotted lists?
macroEval env lisp@(List (Atom x : xs)) = do
  isDefined <- liftIO $ isNamespacedBound env macroNamespace x
  if isDefined
     then do
       syntaxRules@(List (Atom "syntax-rules" : (List identifiers : rules))) <- getNamespacedVar env macroNamespace x 
       -- Transform the input and then call macroEval again, since a macro may be contained within...
       macroEval env =<< macroTransform env (List identifiers) rules lisp
     else do
       rest <- mapM (macroEval env) xs
       return $ List $ (Atom x) : rest
macroEval _ lisp@(_) = return lisp

-- Given input and syntax-rules, determine if any rule is a match and transform it. 
-- TODO (later): validate that the pattern's template and pattern are consistent (IE: no vars in transform that do not appear in matching pattern - csi "stmt1" case)
--macroTransform :: Env -> [LispVal] -> LispVal -> LispVal -> IOThrowsError LispVal
macroTransform env identifiers rules@(rule@(List r) : rs) input = do
  localEnv <- liftIO $ nullEnv -- Local environment used just for this invocation
  result <- matchRule env identifiers localEnv rule input
  case result of 
    Nil _ -> macroTransform env identifiers rs input
    otherwise -> return result
-- Ran out of rules to match...
macroTransform _ _ _ input = throwError $ BadSpecialForm "Input does not match a macro pattern" input

-- Determine if the next element in a list matches 0-to-n times due to an ellipsis
macroElementMatchesMany :: LispVal -> Bool
macroElementMatchesMany (List (p:ps)) = do
  if length ps > 0
     then case (head ps) of
                Atom "..." -> True
                otherwise -> False
     else False
macroElementMatchesMany _ = False

--matchRule :: Env -> Env -> LispVal -> LispVal -> LispVal
matchRule env identifiers localEnv (List [p@(List patternVar), template@(List _)]) (List inputVar) = do
   let is = tail inputVar
   case p of 
      List (Atom _ : ps) -> do
        match <- loadLocal localEnv identifiers (List ps) (List is) False False
        case match of
           Bool False -> do
             return $ Nil "" --throwError $ BadSpecialForm "Input does not match macro pattern" (List is)
           otherwise -> do
		     transformRule localEnv 0 (List []) template (List [])
                     -- DEBUGGING: throwError $ BadSpecialForm "Input does not match macro pattern" (List is)
		     {- DEBUGGING: remove once macro's are working...
                      - trans <- transformRule localEnv 0 (List []) template (List [])
                     --flushStr $ show $ trans

                     temp <- getVar localEnv "vars"
                     temp2 <- getVar localEnv "vals"
                     throwError $ BadSpecialForm "DEBUG" $ List [temp, temp2]
                     throwError $ BadSpecialForm "DEBUG" trans-}
      otherwise -> throwError $ BadSpecialForm "Malformed rule in syntax-rules" p
  where findAtom :: LispVal -> LispVal -> IOThrowsError LispVal
        findAtom (Atom target) (List (Atom a:as)) = do
          if target == a
             then return $ Bool True
             else findAtom (Atom target) (List as)
        findAtom target (List (badtype : _)) = throwError $ TypeMismatch "symbol" badtype -- TODO: test this, non-atoms should throw err
        findAtom target _ = return $ Bool False
  
        --
        -- loadLocal - Determine if pattern matches input, loading input into pattern variables as we go,
        --             in preparation for macro transformation.
        loadLocal :: Env -> LispVal -> LispVal -> LispVal -> Bool -> Bool -> IOThrowsError LispVal
        loadLocal localEnv identifiers pattern input hasEllipsis outerHasEllipsis = do -- TODO: kind of a hack to have both ellipsis vars. Is only outer req'd?
          case (pattern, input) of
               ((DottedList ps p), (DottedList is i)) -> do
                 result <- loadLocal localEnv  identifiers (List ps) (List is) False outerHasEllipsis
                 case result of
                    Bool True -> loadLocal localEnv identifiers p i False outerHasEllipsis
                    otherwise -> return $ Bool False

               (List (p:ps), List (i:is)) -> do -- check first input against first pattern, recurse...

                 let hasEllipsis = macroElementMatchesMany pattern

                 -- TODO: error if ... detected when there is an outer ... ????
                 --       no, this should (eventually) be allowed. See scheme-faq-macros
			 
                 status <- checkLocal localEnv identifiers (hasEllipsis || outerHasEllipsis) p i 
                 case status of
                      -- No match
                      Bool False -> if hasEllipsis
                                        -- No match, must be finished with ...
                                        -- Move past it, but keep the same input.
                                        then loadLocal localEnv identifiers (List $ tail ps) (List (i:is)) False outerHasEllipsis
                                        else return $ Bool False
                      -- There was a match
                      otherwise -> if hasEllipsis
                                      then loadLocal localEnv identifiers pattern (List is) True outerHasEllipsis
                                      else loadLocal localEnv identifiers (List ps) (List is) False outerHasEllipsis

               -- Base case - All data processed
               (List [], List []) -> return $ Bool True

               -- Ran out of input to process
               (List (p:ps), List []) -> do
                                         let hasEllipsis = macroElementMatchesMany pattern
                                         if hasEllipsis && ((length ps) == 1) 
                                                   then return $ Bool True
                                                   else return $ Bool False

               -- Pattern ran out, but there is still input. No match.
               (List [], _) -> return $ Bool False

               -- Check input against pattern (both should be single var)
               (_, _) -> checkLocal localEnv identifiers (hasEllipsis || outerHasEllipsis) pattern input 

        -- Check pattern against input to determine if there is a match
        --
        --  @param localEnv - Local variables for the macro, used during transform
        --  @param hasEllipsis - Determine whether we are in a zero-or-many match.
        --                       Used for loading local vars and NOT for purposes of matching.
        --  @param pattern - Pattern to match
        --  @param input - Input to be matched
        checkLocal :: Env -> LispVal -> Bool -> LispVal -> LispVal -> IOThrowsError LispVal
        checkLocal localEnv identifiers hasEllipsis (Bool pattern) (Bool input) = return $ Bool $ pattern == input
        checkLocal localEnv identifiers hasEllipsis (Number pattern) (Number input) = return $ Bool $ pattern == input
        checkLocal localEnv identifiers hasEllipsis (Float pattern) (Float input) = return $ Bool $ pattern == input
        checkLocal localEnv identifiers hasEllipsis (String pattern) (String input) = return $ Bool $ pattern == input
        checkLocal localEnv identifiers hasEllipsis (Char pattern) (Char input) = return $ Bool $ pattern == input
        checkLocal localEnv identifiers hasEllipsis (Atom pattern) input = do
          if hasEllipsis
             -- Var is part of a 0-to-many match, store up in a list...
             then do isDefined <- liftIO $ isBound localEnv pattern
                     -- If pattern is a literal identifier, then just pass it along as-is
                     found <- findAtom (Atom pattern) identifiers
                     let val = case found of
                                 (Bool True) -> Atom pattern
                                 otherwise -> input
                     -- Set variable in the local environment
                     if isDefined
                        then do v <- getVar localEnv pattern
                                case v of
                                  (List vs) -> setVar localEnv pattern (List $ vs ++ [val])
                        else defineVar localEnv pattern (List [val])
             -- Simple var, load up into macro env
             else defineVar localEnv pattern input
          return $ Bool True

-- TODO, load into localEnv in some (all?) cases?: eqv [(Atom arg1), (Atom arg2)] = return $ Bool $ arg1 == arg2
-- TODO: eqv [(Vector arg1), (Vector arg2)] = eqv [List $ (elems arg1), List $ (elems arg2)] 
--
--      TODO: is this below transform even correct? need to write some test cases for this one...
--            seems correct so far. need to preserve dotted lists and process them in loadLocal - converting
--            them to lists right here seems like the wrong place...
        checkLocal localEnv identifiers hasEllipsis pattern@(DottedList ps p) input@(DottedList is i) = 
          loadLocal localEnv identifiers pattern input False hasEllipsis
        -- Idea here is that if we have a dotted list, the last component does not have to be provided
        -- in the input. So we just need to fill in an empty list for the missing component.
        checkLocal localEnv identifiers hasEllipsis pattern@(DottedList ps p) input@(List (i : is)) = 
          loadLocal localEnv identifiers pattern (DottedList (i : is) (List [])) False hasEllipsis
        checkLocal localEnv identifiers hasEllipsis pattern@(List _) input@(List _) = 
          loadLocal localEnv identifiers pattern input False hasEllipsis

        checkLocal localEnv identifiers hasEllipsis _ _ = return $ Bool False

--
-- TODO: transforming into form (a b) ... does not work at the moment. Causes problems for (let*)
--
-- Transform input by walking the tranform structure and creating a new structure
-- with the same form, replacing identifiers in the tranform with those bound in localEnv
transformRule :: Env -> Int -> LispVal -> LispVal -> LispVal -> IOThrowsError LispVal

-- Recursively transform a list
transformRule localEnv ellipsisIndex (List result) transform@(List(List l : ts)) (List ellipsisList) = do
  let hasEllipsis = macroElementMatchesMany transform
  if hasEllipsis

--
-- LATEST - adding an ellipsisList which will temporarily hold the value of the "outer" result while we process the 
--          zero-or-more match. Once that is complete we will swap this value back into it's rightful place
--

     then do curT <- transformRule localEnv (ellipsisIndex + 1) (List []) (List l) (List result)
--             throwError $ BadSpecialForm "test" $ List [curT, Number $ toInteger ellipsisIndex, List l] -- TODO: debugging
             case curT of
                        -- TODO: this is the same code as below! Once it works, roll both into a common function
               Nil _ -> if ellipsisIndex == 0
                                -- First time through and no match ("zero" case)....
                           then transformRule localEnv 0 (List $ result) (List $ tail ts) (List []) -- tail => Move past the ...
                           else transformRule localEnv 0 (List $ ellipsisList ++ result) (List $ tail ts) (List [])
               List t -> if lastElementIsNil t
			                     -- Base case, there is no more data to transform for this ellipsis
                            -- 0 (and above nesting) means we cannot allow more than one ... active at a time (OK per spec???)
                            then if ellipsisIndex == 0
                                         -- First time through and no match ("zero" case)....
                                    then transformRule localEnv 0 (List $ result) (List $ tail ts) (List [])
                                    else transformRule localEnv 0 (List $ ellipsisList ++ result) (List $ tail ts) (List [])
			                     -- Next iteration of the zero-to-many match
                            else do if ellipsisIndex == 0
                                    -- First time through, swap out result
                                      then do 
                                              transformRule localEnv (ellipsisIndex + 1) (List [curT]) transform (List result)
                                    -- Keep going...
                                      else do 
                                              transformRule localEnv (ellipsisIndex + 1) (List $ result ++ [curT]) transform (List ellipsisList)

     else do lst <- transformRule localEnv ellipsisIndex (List []) (List l) (List ellipsisList)
             case lst of
                  List _ -> transformRule localEnv ellipsisIndex (List $ result ++ [lst]) (List ts) (List ellipsisList)
                  otherwise -> throwError $ BadSpecialForm "Macro transform error" $ List [lst, (List l), Number $ toInteger ellipsisIndex]

  where lastElementIsNil l = case (last l) of
                               Nil _ -> True
                               otherwise -> False
        getListAtTail l = case (last l) of
                               List lst -> lst

-- TODO: vector transform (and taking vectors into account in other cases as well???)
-- TODO: what about dotted lists?

-- Transform an atom by attempting to look it up as a var...
transformRule localEnv ellipsisIndex (List result) transform@(List (Atom a : ts)) unused = do
  let hasEllipsis = macroElementMatchesMany transform
  isDefined <- liftIO $ isBound localEnv a
  if hasEllipsis
     then if isDefined
             then do
                  -- get var
                  var <- getVar localEnv a
                  -- ensure it is a list
                  case var of 
                    -- add all elements of the list into result
                    List v -> transformRule localEnv ellipsisIndex (List $ result ++ v) (List $ tail ts) unused
                    v@(_) -> transformRule localEnv ellipsisIndex (List $ result ++ [v]) (List $ tail ts) unused
             else -- Matched 0 times, skip it
                  transformRule localEnv ellipsisIndex (List result) (List $ tail ts) unused
     else do t <- if isDefined
                     then do var <- getVar localEnv a
                             if ellipsisIndex > 0 
                                then do case var of
                                          List v -> if (length v) > (ellipsisIndex - 1)
                                                       then return $ v !! (ellipsisIndex - 1)
                                                       else return $ Nil ""
					            else return var
                     else if ellipsisIndex > 0
                             then return $ Nil "" -- Zero-match case
                             else return $ Atom a -- Not defined in the macro, just pass it through the macro as-is
             case t of
               Nil _ -> return t
               otherwise -> transformRule localEnv ellipsisIndex (List $ result ++ [t]) (List ts) unused

-- Transform anything else as itself...
transformRule localEnv ellipsisIndex result@(List r) transform@(List (t : ts)) unused = do
  transformRule localEnv ellipsisIndex (List $ r ++ [t]) (List ts) unused

-- Base case - empty transform
transformRule localEnv ellipsisIndex result@(List _) transform@(List []) unused = do
  return result

