{-# LANGUAGE CPP #-}

module RnSplice (
        rnTopSpliceDecls,
        rnSpliceType, rnSpliceExpr, rnSplicePat, rnSpliceDecl,
        rnBracket,
        checkThLocalName
#ifdef GHCI
        , traceSplice, SpliceInfo(..)
#endif
  ) where

#include "HsVersions.h"

import Name
import NameSet
import HsSyn
import RdrName
import TcRnMonad
import Kind

import RnEnv
import RnSource         ( rnSrcDecls, findSplice )
import RnPat            ( rnPat )
import BasicTypes       ( TopLevelFlag, isTopLevel )
import Outputable
import Module
import SrcLoc
import DynFlags
import FastString
import RnTypes          ( rnLHsType )

import Control.Monad    ( unless, when )

import {-# SOURCE #-} RnExpr   ( rnLExpr )

import PrelNames        ( isUnboundName )
import TcEnv            ( checkWellStaged )
import THNames          ( liftName )

#ifdef GHCI
import ErrUtils         ( dumpIfSet_dyn_printer )
import TcEnv            ( tcMetaTy )
import Hooks
import Var              ( Id )
import THNames          ( quoteExpName, quotePatName, quoteDecName, quoteTypeName
                        , decsQTyConName, expQTyConName, patQTyConName, typeQTyConName, )
import Util

import {-# SOURCE #-} TcExpr   ( tcMonoExpr )
import {-# SOURCE #-} TcSplice ( runMetaD, runMetaE, runMetaP, runMetaT, tcTopSpliceExpr )
#endif

{-
************************************************************************
*                                                                      *
        Template Haskell brackets
*                                                                      *
************************************************************************
-}

rnBracket :: HsExpr RdrName -> HsBracket RdrName -> RnM (HsExpr Name, FreeVars)
rnBracket e br_body
  = addErrCtxt (quotationCtxtDoc br_body) $
    do { -- Check that Template Haskell is enabled and available
         thEnabled <- xoptM Opt_TemplateHaskell
       ; unless thEnabled $
           failWith ( vcat [ ptext (sLit "Syntax error on") <+> ppr e
                           , ptext (sLit "Perhaps you intended to use TemplateHaskell") ] )

         -- Check for nested brackets
       ; cur_stage <- getStage
       ; case cur_stage of
           { Splice True  -> checkTc (isTypedBracket br_body) illegalUntypedBracket
           ; Splice False -> checkTc (not (isTypedBracket br_body)) illegalTypedBracket
           ; Comp         -> return ()
           ; Brack {}     -> failWithTc illegalBracket
           }

         -- Brackets are desugared to code that mentions the TH package
       ; recordThUse

       ; case isTypedBracket br_body of
            True  -> do { (body', fvs_e) <- setStage (Brack cur_stage RnPendingTyped) $
                                            rn_bracket cur_stage br_body
                        ; return (HsBracket body', fvs_e) }

            False -> do { ps_var <- newMutVar []
                        ; (body', fvs_e) <- setStage (Brack cur_stage (RnPendingUntyped ps_var)) $
                                            rn_bracket cur_stage br_body
                        ; pendings <- readMutVar ps_var
                        ; return (HsRnBracketOut body' pendings, fvs_e) }
       }

rn_bracket :: ThStage -> HsBracket RdrName -> RnM (HsBracket Name, FreeVars)
rn_bracket outer_stage br@(VarBr flg rdr_name)
  = do { name <- lookupOccRn rdr_name
       ; this_mod <- getModule

       ; when (flg && nameIsLocalOrFrom this_mod name) $
             -- Type variables can be quoted in TH. See #5721.
                 do { mb_bind_lvl <- lookupLocalOccThLvl_maybe name
                    ; case mb_bind_lvl of
                        { Nothing -> return ()      -- Can happen for data constructors,
                                                    -- but nothing needs to be done for them

                        ; Just (top_lvl, bind_lvl)  -- See Note [Quoting names]
                             | isTopLevel top_lvl
                             -> when (isExternalName name) (keepAlive name)
                             | otherwise
                             -> do { traceRn (text "rn_bracket VarBr" <+> ppr name <+> ppr bind_lvl <+> ppr outer_stage)
                                   ; checkTc (thLevel outer_stage + 1 == bind_lvl)
                                             (quotedNameStageErr br) }
                        }
                    }
       ; return (VarBr flg name, unitFV name) }

rn_bracket _ (ExpBr e) = do { (e', fvs) <- rnLExpr e
                            ; return (ExpBr e', fvs) }

rn_bracket _ (PatBr p) = rnPat ThPatQuote p $ \ p' -> return (PatBr p', emptyFVs)

rn_bracket _ (TypBr t) = do { (t', fvs) <- rnLHsType TypBrCtx t
                            ; return (TypBr t', fvs) }

rn_bracket _ (DecBrL decls)
  = do { group <- groupDecls decls
       ; gbl_env  <- getGblEnv
       ; let new_gbl_env = gbl_env { tcg_dus = emptyDUs }
                          -- The emptyDUs is so that we just collect uses for this
                          -- group alone in the call to rnSrcDecls below
       ; (tcg_env, group') <- setGblEnv new_gbl_env $
                              rnSrcDecls Nothing group

              -- Discard the tcg_env; it contains only extra info about fixity
        ; traceRn (text "rn_bracket dec" <+> (ppr (tcg_dus tcg_env) $$
                   ppr (duUses (tcg_dus tcg_env))))
        ; return (DecBrG group', duUses (tcg_dus tcg_env)) }
  where
    groupDecls :: [LHsDecl RdrName] -> RnM (HsGroup RdrName)
    groupDecls decls
      = do { (group, mb_splice) <- findSplice decls
           ; case mb_splice of
           { Nothing -> return group
           ; Just (splice, rest) ->
               do { group' <- groupDecls rest
                  ; let group'' = appendGroups group group'
                  ; return group'' { hs_splcds = noLoc splice : hs_splcds group' }
                  }
           }}

rn_bracket _ (DecBrG _) = panic "rn_bracket: unexpected DecBrG"

rn_bracket _ (TExpBr e) = do { (e', fvs) <- rnLExpr e
                             ; return (TExpBr e', fvs) }

quotationCtxtDoc :: HsBracket RdrName -> SDoc
quotationCtxtDoc br_body
  = hang (ptext (sLit "In the Template Haskell quotation"))
         2 (ppr br_body)

illegalBracket :: SDoc
illegalBracket = ptext (sLit "Template Haskell brackets cannot be nested (without intervening splices)")

illegalTypedBracket :: SDoc
illegalTypedBracket = ptext (sLit "Typed brackets may only appear in typed slices.")

illegalUntypedBracket :: SDoc
illegalUntypedBracket = ptext (sLit "Untyped brackets may only appear in untyped slices.")

quotedNameStageErr :: HsBracket RdrName -> SDoc
quotedNameStageErr br
  = sep [ ptext (sLit "Stage error: the non-top-level quoted name") <+> ppr br
        , ptext (sLit "must be used at the same stage at which is is bound")]

#ifndef GHCI
rnTopSpliceDecls :: HsSplice RdrName -> RnM ([LHsDecl RdrName], FreeVars)
rnTopSpliceDecls e = failTH e "Template Haskell top splice"

rnSpliceType :: HsSplice RdrName -> PostTc Name Kind
             -> RnM (HsType Name, FreeVars)
rnSpliceType e _ = failTH e "Template Haskell type splice"

rnSpliceExpr :: HsSplice RdrName -> RnM (HsExpr Name, FreeVars)
rnSpliceExpr e = failTH e "Template Haskell splice"

rnSplicePat :: HsSplice RdrName -> RnM (Either (Pat RdrName) (Pat Name), FreeVars)
rnSplicePat e = failTH e "Template Haskell pattern splice"

rnSpliceDecl :: SpliceDecl RdrName -> RnM (SpliceDecl Name, FreeVars)
rnSpliceDecl e = failTH e "Template Haskell declaration splice"
#else

{-
*********************************************************
*                                                      *
                Splices
*                                                      *
*********************************************************

Note [Free variables of typed splices]
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
Consider renaming this:
        f = ...
        h = ...$(thing "f")...

where the splice is a *typed* splice.  The splice can expand into
literally anything, so when we do dependency analysis we must assume
that it might mention 'f'.  So we simply treat all locally-defined
names as mentioned by any splice.  This is terribly brutal, but I
don't see what else to do.  For example, it'll mean that every
locally-defined thing will appear to be used, so no unused-binding
warnings.  But if we miss the dependency, then we might typecheck 'h'
before 'f', and that will crash the type checker because 'f' isn't in
scope.

Currently, I'm not treating a splice as also mentioning every import,
which is a bit inconsistent -- but there are a lot of them.  We might
thereby get some bogus unused-import warnings, but we won't crash the
type checker.  Not very satisfactory really.

Note [Renamer errors]
~~~~~~~~~~~~~~~~~~~~~
It's important to wrap renamer calls in checkNoErrs, because the
renamer does not fail for out of scope variables etc. Instead it
returns a bogus term/type, so that it can report more than one error.
We don't want the type checker to see these bogus unbound variables.
-}

rnSpliceGen :: (HsSplice Name -> RnM (a, FreeVars))     -- Outside brackets, run splice
            -> (HsSplice Name -> (PendingRnSplice, a))  -- Inside brackets, make it pending
            -> HsSplice RdrName
            -> RnM (a, FreeVars)
rnSpliceGen run_splice pend_splice splice
  = addErrCtxt (spliceCtxt splice) $ do
    { stage <- getStage
    ; case stage of
        Brack pop_stage RnPendingTyped
          -> do { checkTc is_typed_splice illegalUntypedSplice
                ; (splice', fvs) <- setStage pop_stage $
                                    rnSplice splice
                ; let (_pending_splice, result) = pend_splice splice'
                ; return (result, fvs) }

        Brack pop_stage (RnPendingUntyped ps_var)
          -> do { checkTc (not is_typed_splice) illegalTypedSplice
                ; (splice', fvs) <- setStage pop_stage $
                                    rnSplice splice
                ; let (pending_splice, result) = pend_splice splice'
                ; ps <- readMutVar ps_var
                ; writeMutVar ps_var (pending_splice : ps)
                ; return (result, fvs) }

        _ ->  do { (splice', fvs1) <- checkNoErrs $
                                      setStage (Splice is_typed_splice) $
                                      rnSplice splice
                   -- checkNoErrs: don't attempt to run the splice if
                   -- renaming it failed; otherwise we get a cascade of
                   -- errors from e.g. unbound variables
                 ; (result, fvs2) <- run_splice splice'
                 ; return (result, fvs1 `plusFV` fvs2) } }
   where
     is_typed_splice = isTypedSplice splice

------------------
runRnSplice :: UntypedSpliceFlavour
            -> (LHsExpr Id -> TcRn res)
            -> (res -> SDoc)    -- How to pretty-print res
                                -- Usually just ppr, but not for [Decl]
            -> HsSplice Name    -- Always untyped
            -> TcRn res
runRnSplice flavour run_meta ppr_res splice
  = do { splice' <- getHooked runRnSpliceHook return >>= ($ splice)

       ; let the_expr = case splice' of
                  HsUntypedSplice _ e     ->  e
                  HsQuasiQuote _ q qs str -> mkQuasiQuoteExpr flavour q qs str
                  HsTypedSplice {}        -> pprPanic "runRnSplice" (ppr splice)

             -- Typecheck the expression
       ; meta_exp_ty   <- tcMetaTy meta_ty_name
       ; zonked_q_expr <- tcTopSpliceExpr False $
                          tcMonoExpr the_expr meta_exp_ty

             -- Run the expression
       ; result <- run_meta zonked_q_expr
       ; traceSplice (SpliceInfo { spliceDescription = what
                                 , spliceIsDecl      = is_decl
                                 , spliceSource      = Just the_expr
                                 , spliceGenerated   = ppr_res result })

       ; return result }

  where
    meta_ty_name = case flavour of
                       UntypedExpSplice  -> expQTyConName
                       UntypedPatSplice  -> patQTyConName
                       UntypedTypeSplice -> typeQTyConName
                       UntypedDeclSplice -> decsQTyConName
    what = case flavour of
                  UntypedExpSplice  -> "expression"
                  UntypedPatSplice  -> "pattern"
                  UntypedTypeSplice -> "type"
                  UntypedDeclSplice -> "declarations"
    is_decl = case flavour of
                 UntypedDeclSplice -> True
                 _                 -> False

------------------
makePending :: UntypedSpliceFlavour
            -> HsSplice Name
            -> PendingRnSplice
makePending flavour (HsUntypedSplice n e)
  = PendingRnSplice flavour n e
makePending flavour (HsQuasiQuote n quoter q_span quote)
  = PendingRnSplice flavour n (mkQuasiQuoteExpr flavour quoter q_span quote)
makePending _ splice@(HsTypedSplice {})
  = pprPanic "makePending" (ppr splice)

------------------
mkQuasiQuoteExpr :: UntypedSpliceFlavour -> Name -> SrcSpan -> FastString -> LHsExpr Name
-- Return the expression (quoter "...quote...")
-- which is what we must run in a quasi-quote
mkQuasiQuoteExpr flavour quoter q_span quote
  = L q_span $ HsApp (L q_span $
                      HsApp (L q_span (HsVar quote_selector)) quoterExpr)
                     quoteExpr
  where
    quoterExpr = L q_span $! HsVar $! quoter
    quoteExpr  = L q_span $! HsLit $! HsString "" quote
    quote_selector = case flavour of
                       UntypedExpSplice  -> quoteExpName
                       UntypedPatSplice  -> quotePatName
                       UntypedTypeSplice -> quoteTypeName
                       UntypedDeclSplice -> quoteDecName

---------------------
rnSplice :: HsSplice RdrName -> RnM (HsSplice Name, FreeVars)
-- Not exported...used for all
rnSplice (HsTypedSplice splice_name expr)
  = do  { checkTH expr "Template Haskell typed splice"
        ; loc  <- getSrcSpanM
        ; n' <- newLocalBndrRn (L loc splice_name)
        ; (expr', fvs) <- rnLExpr expr
        ; return (HsTypedSplice n' expr', fvs) }

rnSplice (HsUntypedSplice splice_name expr)
  = do  { checkTH expr "Template Haskell untyped splice"
        ; loc  <- getSrcSpanM
        ; n' <- newLocalBndrRn (L loc splice_name)
        ; (expr', fvs) <- rnLExpr expr
        ; return (HsUntypedSplice n' expr', fvs) }

rnSplice (HsQuasiQuote splice_name quoter q_loc quote)
  = do  { checkTH quoter "Template Haskell quasi-quote"
        ; loc  <- getSrcSpanM
        ; splice_name' <- newLocalBndrRn (L loc splice_name)

          -- Drop the leading "$" from the quoter name, if present
          -- This is old-style syntax, now deprecated
          -- NB: when removing this backward-compat, remove
          --     the matching code in Lexer.x (around line 310)
        ; let occ_str = occNameString (rdrNameOcc quoter)
        ; quoter <- if ASSERT( not (null occ_str) )  -- Lexer ensures this
                       head occ_str /= '$'
                    then return quoter
                    else do { addWarn (deprecatedDollar quoter)
                            ; return (mkRdrUnqual (mkVarOcc (tail occ_str))) }

          -- Rename the quoter; akin to the HsVar case of rnExpr
        ; quoter' <- lookupOccRn quoter
        ; this_mod <- getModule
        ; when (nameIsLocalOrFrom this_mod quoter') $
          checkThLocalName quoter'

        ; return (HsQuasiQuote splice_name' quoter' q_loc quote, unitFV quoter') }

deprecatedDollar :: RdrName -> SDoc
deprecatedDollar quoter
  = hang (ptext (sLit "Deprecated syntax:"))
       2 (ptext (sLit "quasiquotes no longer need a dollar sign:")
          <+> ppr quoter)


---------------------
rnSpliceExpr :: HsSplice RdrName -> RnM (HsExpr Name, FreeVars)
rnSpliceExpr splice
  = rnSpliceGen run_expr_splice pend_expr_splice splice
  where
    pend_expr_splice :: HsSplice Name -> (PendingRnSplice, HsExpr Name)
    pend_expr_splice rn_splice
        = (makePending UntypedExpSplice rn_splice, HsSpliceE rn_splice)

    run_expr_splice :: HsSplice Name -> RnM (HsExpr Name, FreeVars)
    run_expr_splice rn_splice
      | isTypedSplice rn_splice   -- Run it later, in the type checker
      = do {  -- Ugh!  See Note [Splices] above
             lcl_rdr <- getLocalRdrEnv
           ; gbl_rdr <- getGlobalRdrEnv
           ; let gbl_names = mkNameSet [gre_name gre | gre <- globalRdrEnvElts gbl_rdr
                                                     , isLocalGRE gre]
                 lcl_names = mkNameSet (localRdrEnvElts lcl_rdr)

           ; return (HsSpliceE rn_splice, lcl_names `plusFV` gbl_names) }

      | otherwise  -- Run it here
      = do { rn_expr <- runRnSplice UntypedExpSplice runMetaE ppr rn_splice
           ; (lexpr3, fvs) <- checkNoErrs (rnLExpr rn_expr)
           ; return (HsPar lexpr3, fvs)  }

----------------------
rnSpliceType :: HsSplice RdrName -> PostTc Name Kind
             -> RnM (HsType Name, FreeVars)
rnSpliceType splice k
  = rnSpliceGen run_type_splice pend_type_splice splice
  where
    pend_type_splice rn_splice
       = (makePending UntypedTypeSplice rn_splice, HsSpliceTy rn_splice k)

    run_type_splice rn_splice
      = do { hs_ty2 <- runRnSplice UntypedTypeSplice runMetaT ppr rn_splice
           ; (hs_ty3, fvs) <- do { let doc = SpliceTypeCtx hs_ty2
                                 ; checkNoErrs $ rnLHsType doc hs_ty2 }
                                    -- checkNoErrs: see Note [Renamer errors]
           ; return (HsParTy hs_ty3, fvs) }
              -- Wrap the result of the splice in parens so that we don't
              -- lose the outermost location set by runQuasiQuote (#7918)

----------------------
-- | Rename a splice pattern. See Note [rnSplicePat]
rnSplicePat :: HsSplice RdrName -> RnM ( Either (Pat RdrName) (Pat Name)
                                       , FreeVars)
rnSplicePat splice
  = rnSpliceGen run_pat_splice pend_pat_splice splice
  where
    pend_pat_splice rn_splice
      = (makePending UntypedPatSplice rn_splice, Right (SplicePat rn_splice))

    run_pat_splice rn_splice
      = do { pat <- runRnSplice UntypedPatSplice runMetaP ppr rn_splice
           ; return (Left (ParPat pat), emptyFVs) }
              -- Wrap the result of the quasi-quoter in parens so that we don't
              -- lose the outermost location set by runQuasiQuote (#7918)

----------------------
rnSpliceDecl :: SpliceDecl RdrName -> RnM (SpliceDecl Name, FreeVars)
rnSpliceDecl (SpliceDecl (L loc splice) flg)
  = rnSpliceGen run_decl_splice pend_decl_splice splice
  where
    pend_decl_splice rn_splice
       = (makePending UntypedDeclSplice rn_splice, SpliceDecl (L loc rn_splice) flg)

    run_decl_splice rn_splice = pprPanic "rnSpliceDecl" (ppr rn_splice)

rnTopSpliceDecls :: HsSplice RdrName -> RnM ([LHsDecl RdrName], FreeVars)
-- Declaration splice at the very top level of the module
rnTopSpliceDecls splice
   = do  { (rn_splice, fvs) <- setStage (Splice False) $
                               rnSplice splice
         ; decls <- runRnSplice UntypedDeclSplice runMetaD ppr_decls rn_splice
         ; return (decls,fvs) }
   where
     ppr_decls :: [LHsDecl RdrName] -> SDoc
     ppr_decls ds = vcat (map ppr ds)

{-
Note [rnSplicePat]
~~~~~~~~~~~~~~~~~~
Renaming a pattern splice is a bit tricky, because we need the variables
bound in the pattern to be in scope in the RHS of the pattern. This scope
management is effectively done by using continuation-passing style in
RnPat, through the CpsRn monad. We don't wish to be in that monad here
(it would create import cycles and generally conflict with renaming other
splices), so we really want to return a (Pat RdrName) -- the result of
running the splice -- which can then be further renamed in RnPat, in
the CpsRn monad.

The problem is that if we're renaming a splice within a bracket, we
*don't* want to run the splice now. We really do just want to rename
it to an HsSplice Name. Of course, then we can't know what variables
are bound within the splice, so pattern splices within brackets aren't
all that useful.

In any case, when we're done in rnSplicePat, we'll either have a
Pat RdrName (the result of running a top-level splice) or a Pat Name
(the renamed nested splice). Thus, the awkward return type of
rnSplicePat.
-}

spliceCtxt :: HsSplice RdrName -> SDoc
spliceCtxt splice
  = hang (ptext (sLit "In the") <+> what) 2 (ppr splice)
  where
    what = case splice of
             HsUntypedSplice {} -> ptext (sLit "untyped splice:")
             HsTypedSplice   {} -> ptext (sLit "typed splice:")
             HsQuasiQuote    {} -> ptext (sLit "quasi-quotation:")

-- | The splice data to be logged
data SpliceInfo
  = SpliceInfo
    { spliceDescription   :: String
    , spliceSource        :: Maybe (LHsExpr Name)  -- Nothing <=> top-level decls
                                                   --        added by addTopDecls
    , spliceIsDecl        :: Bool    -- True <=> put the generate code in a file
                                     --          when -dth-dec-file is on
    , spliceGenerated     :: SDoc
    }
        -- Note that 'spliceSource' is *renamed* but not *typechecked*
        -- Reason (a) less typechecking crap
        --        (b) data constructors after type checking have been
        --            changed to their *wrappers*, and that makes them
        --            print always fully qualified

-- | outputs splice information for 2 flags which have different output formats:
-- `-ddump-splices` and `-dth-dec-file`
traceSplice :: SpliceInfo -> TcM ()
traceSplice (SpliceInfo { spliceDescription = sd, spliceSource = mb_src
                        , spliceGenerated = gen, spliceIsDecl = is_decl })
  = do { loc <- case mb_src of
                   Nothing        -> getSrcSpanM
                   Just (L loc _) -> return loc
       ; traceOptTcRn Opt_D_dump_splices (spliceDebugDoc loc)

       ; when is_decl $  -- Raw material for -dth-dec-file
         do { dflags <- getDynFlags
            ; liftIO $ dumpIfSet_dyn_printer alwaysQualify dflags Opt_D_th_dec_file
                                             (spliceCodeDoc loc) } }
  where
    -- `-ddump-splices`
    spliceDebugDoc :: SrcSpan -> SDoc
    spliceDebugDoc loc
      = let code = case mb_src of
                     Nothing -> ending
                     Just e  -> nest 2 (ppr e) : ending
            ending = [ text "======>", nest 2 gen ]
        in  hang (ppr loc <> colon <+> text "Splicing" <+> text sd)
               2 (sep code)

    -- `-dth-dec-file`
    spliceCodeDoc :: SrcSpan -> SDoc
    spliceCodeDoc loc
      = vcat [ text "--" <+> ppr loc <> colon <+> text "Splicing" <+> text sd
             , gen ]

illegalTypedSplice :: SDoc
illegalTypedSplice = ptext (sLit "Typed splices may not appear in untyped brackets")

illegalUntypedSplice :: SDoc
illegalUntypedSplice = ptext (sLit "Untyped splices may not appear in typed brackets")

-- spliceResultDoc :: OutputableBndr id => LHsExpr id -> SDoc
-- spliceResultDoc expr
--  = vcat [ hang (ptext (sLit "In the splice:"))
--              2 (char '$' <> pprParendExpr expr)
--        , ptext (sLit "To see what the splice expanded to, use -ddump-splices") ]
#endif

checkThLocalName :: Name -> RnM ()
checkThLocalName name
  | isUnboundName name   -- Do not report two errors for
  = return ()            --   $(not_in_scope args)

  | otherwise
  = do  { traceRn (text "checkThLocalName" <+> ppr name)
        ; mb_local_use <- getStageAndBindLevel name
        ; case mb_local_use of {
             Nothing -> return () ;  -- Not a locally-bound thing
             Just (top_lvl, bind_lvl, use_stage) ->
    do  { let use_lvl = thLevel use_stage
        ; checkWellStaged (quotes (ppr name)) bind_lvl use_lvl
        ; traceRn (text "checkThLocalName" <+> ppr name <+> ppr bind_lvl <+> ppr use_stage <+> ppr use_lvl)
        ; checkCrossStageLifting top_lvl bind_lvl use_stage use_lvl name } } }

--------------------------------------
checkCrossStageLifting :: TopLevelFlag -> ThLevel -> ThStage -> ThLevel
                       -> Name -> TcM ()
-- We are inside brackets, and (use_lvl > bind_lvl)
-- Now we must check whether there's a cross-stage lift to do
-- Examples   \x -> [| x |]
--            [| map |]
--
-- This code is similar to checkCrossStageLifting in TcExpr, but
-- this is only run on *untyped* brackets.

checkCrossStageLifting top_lvl bind_lvl use_stage use_lvl name
  | Brack _ (RnPendingUntyped ps_var) <- use_stage   -- Only for untyped brackets
  , use_lvl > bind_lvl                               -- Cross-stage condition
  = check_cross_stage_lifting top_lvl name ps_var
  | otherwise
  = return ()

check_cross_stage_lifting :: TopLevelFlag -> Name -> TcRef [PendingRnSplice] -> TcM ()
check_cross_stage_lifting top_lvl name ps_var
  | isTopLevel top_lvl
        -- Top-level identifiers in this module,
        -- (which have External Names)
        -- are just like the imported case:
        -- no need for the 'lifting' treatment
        -- E.g.  this is fine:
        --   f x = x
        --   g y = [| f 3 |]
  = when (isExternalName name) (keepAlive name)
    -- See Note [Keeping things alive for Template Haskell]

  | otherwise
  =     -- Nested identifiers, such as 'x' in
        -- E.g. \x -> [| h x |]
        -- We must behave as if the reference to x was
        --      h $(lift x)
        -- We use 'x' itself as the SplicePointName, used by
        -- the desugarer to stitch it all back together.
        -- If 'x' occurs many times we may get many identical
        -- bindings of the same SplicePointName, but that doesn't
        -- matter, although it's a mite untidy.
    do  { traceRn (text "checkCrossStageLifting" <+> ppr name)

          -- Construct the (lift x) expression
        ; let lift_expr   = nlHsApp (nlHsVar liftName) (nlHsVar name)
              pend_splice = PendingRnSplice UntypedExpSplice name lift_expr

          -- Update the pending splices
        ; ps <- readMutVar ps_var
        ; writeMutVar ps_var (pend_splice : ps) }

{-
Note [Keeping things alive for Template Haskell]
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
Consider
  f x = x+1
  g y = [| f 3 |]

Here 'f' is referred to from inside the bracket, which turns into data
and mentions only f's *name*, not 'f' itself. So we need some other
way to keep 'f' alive, lest it get dropped as dead code.  That's what
keepAlive does. It puts it in the keep-alive set, which subsequently
ensures that 'f' stays as a top level binding.

This must be done by the renamer, not the type checker (as of old),
because the type checker doesn't typecheck the body of untyped
brackets (Trac #8540).

A thing can have a bind_lvl of outerLevel, but have an internal name:
   foo = [d| op = 3
             bop = op + 1 |]
Here the bind_lvl of 'op' is (bogusly) outerLevel, even though it is
bound inside a bracket.  That is because we don't even even record
binding levels for top-level things; the binding levels are in the
LocalRdrEnv.

So the occurrence of 'op' in the rhs of 'bop' looks a bit like a
cross-stage thing, but it isn't really.  And in fact we never need
to do anything here for top-level bound things, so all is fine, if
a bit hacky.

For these chaps (which have Internal Names) we don't want to put
them in the keep-alive set.

Note [Quoting names]
~~~~~~~~~~~~~~~~~~~~
A quoted name 'n is a bit like a quoted expression [| n |], except that we
have no cross-stage lifting (c.f. TcExpr.thBrackId).  So, after incrementing
the use-level to account for the brackets, the cases are:

        bind > use                      Error
        bind = use+1                    OK
        bind < use
                Imported things         OK
                Top-level things        OK
                Non-top-level           Error

where 'use' is the binding level of the 'n quote. (So inside the implied
bracket the level would be use+1.)

Examples:

  f 'map        -- OK; also for top-level defns of this module

  \x. f 'x      -- Not ok (bind = 1, use = 1)
                -- (whereas \x. f [| x |] might have been ok, by
                --                               cross-stage lifting

  \y. [| \x. $(f 'y) |] -- Not ok (bind =1, use = 1)

  [| \x. $(f 'x) |]     -- OK (bind = 2, use = 1)
-}
