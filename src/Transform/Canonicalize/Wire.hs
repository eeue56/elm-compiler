module Transform.Canonicalize.Wire (checkInput, checkOutput, loopback) where

import Control.Applicative ((<$>))
import Control.Monad.Error (forM_, throwError)
import Text.PrettyPrint as P

import qualified AST.Declaration as D
import qualified AST.Expression.Canonical as Canonical
import qualified AST.PrettyPrint as PP
import qualified AST.Type as ST
import qualified AST.Variable as Var
import qualified Transform.Canonicalize.Environment as Env


throw :: [Doc] -> Env.Canonicalizer [P.Doc] a
throw err =
  throwError [ P.vcat err ]


checkInput :: String -> ST.CanonicalType -> Env.Canonicalizer [P.Doc] ()
checkInput name tipe =
    checkWire In name tipe tipe


checkOutput :: String -> ST.CanonicalType -> Env.Canonicalizer [P.Doc] ()
checkOutput name tipe =
    checkWire Out name tipe tipe


data Direction = In | Out


checkWire
    :: Direction
    -> String
    -> ST.CanonicalType
    -> ST.CanonicalType
    -> Env.Canonicalizer [P.Doc] ()
checkWire direction name rootType tipe =
  case tipe of
    ST.Aliased _ args t ->
        checkWire direction name rootType (ST.dealias args t)

    ST.App (ST.Type signal) [t]
        | Var.isStream signal ->
            validWireType False (Just Stream) direction name rootType t

        | Var.isVarying signal ->
            validWireType False (Just Varying) direction name rootType t

    _ ->
        validWireType False Nothing direction name rootType tipe


data Signal = Stream | Varying


validWireType
    :: Bool
    -> Maybe Signal
    -> Direction
    -> String
    -> ST.CanonicalType
    -> ST.CanonicalType
    -> Env.Canonicalizer [P.Doc] ()
validWireType seenFunc seenSignal direction name rootType tipe =
    let valid localType =
            validWireType seenFunc seenSignal direction name rootType localType

        err kind =
            throw (wireError name direction rootType tipe kind)
    in
    case tipe of
      ST.Aliased _ args t ->
          valid (ST.dealias args t)

      ST.Type v ->
          case any ($ v) [ Var.isJson, Var.isPrimitive, Var.isTuple ] of
            True -> return ()
            False -> err "It contains an unsupported type"

      ST.App t [] ->
          valid t

      ST.App (ST.Type v) [t]
          | Var.isMaybe v -> valid t
          | Var.isArray v -> valid t
          | Var.isList  v -> valid t

      ST.App (ST.Type v) ts
          | Var.isTuple v -> mapM_ valid ts

      ST.App _ _ ->
          err "It contains an unsupported type"

      ST.Var _ ->
          err "It contains a free type variable"

      ST.Lambda _ _ ->
          case direction of
            In -> err "It contains functions"
            Out ->
              if seenFunc
                then err "It contains higher-order functions"
                else
                  case seenSignal of
                    Just Stream ->
                        err "It is a streams that contains a function"

                    Just Varying ->
                        err "It is a varying value that contains a function"

                    Nothing ->
                        forM_ (ST.collectLambdas tipe)
                              (validWireType True seenSignal direction name rootType)

      ST.Record _ (Just _) ->
          err "It contains extended records with free type variables"

      ST.Record fields Nothing ->
          mapM_ (\(k,v) -> (,) k <$> valid v) fields


wireError
    :: String
    -> Direction
    -> ST.CanonicalType
    -> ST.CanonicalType
    -> String
    -> [P.Doc]
wireError name direction rootType localType problemMessage =
    [ P.text (dir "Input" "Output" ++ " Error:")
    , P.nest 4 $
        P.vcat
          [ txt [ "The ", wire, " named '", name, "' has an invalid type.\n" ]
          , P.nest 4 (PP.pretty rootType) <> P.text "\n"
          , txt [ problemMessage, ":\n" ]
          , P.nest 4 (PP.pretty localType) <> P.text "\n"
          , txt [ "Acceptable values for ", wire, "s include:" ]
          , txt [ "  Ints, Floats, Bools, Strings, Maybes, Lists, Arrays, Tuples, unit values," ]
          , txt [ "  Json.Values, ", dir "" "first-order functions, promises, ", "and concrete records." ]
          ]
    ]
  where
    dir inMsg outMsg =
        case direction of
          In -> inMsg
          Out -> outMsg

    txt = P.text . concat

    wire =
        dir "input" "output"


loopback
    :: String
    -> Maybe Canonical.Expr
    -> ST.CanonicalType
    -> Env.Canonicalizer [P.Doc] D.CanonicalLoopback
loopback name maybeExpr tipe =
  case maybeExpr of
    Nothing ->
        case ST.deepDealias tipe of
          ST.Record
            [ ("mailbox", ST.App (ST.Type mailbox) [a])
            , ("stream", ST.App (ST.Type stream) [b])
            ]
            Nothing
              | Var.isStream stream && Var.isMailbox mailbox && a == b ->
                  return (D.Mailbox name tipe)


          _ ->
              throw $ loopbackError name tipe $
                [ P.text "A loopback like this must be a WritableStream." ]

    Just expr ->
        case ST.deepDealias tipe of
          ST.App (ST.Type signal) [ ST.App (ST.Type result) [failure,success] ]
              | Var.isStream signal && Var.isResult result ->
                  let promise =
                        Var.fromModule ["Promise"] "Promise"
                      promiseType =
                        ST.App (ST.Type signal) [ ST.App (ST.Type promise) [failure,success] ]
                  in
                      return (D.Promise name promiseType expr tipe)

          _ ->
              throw $ loopbackError name tipe $
                [ P.text "A loopback that runs promises must be a stream of results."
                , P.text "Something like the following:\n"
                , P.text "    Stream (Result Http.Error String)"
                , P.text "    Stream (Result x ())"
                ]


loopbackError :: String -> ST.CanonicalType -> [Doc] -> [Doc]
loopbackError name tipe message =
  [ P.text "Loopback Error:"
  , P.nest 4 $
      P.vcat $
        [ P.text ("The loopback named '" ++ name ++ "' has an invalid type.\n")
        , P.nest 4 (PP.pretty tipe) <> P.text "\n"
        ]
        ++ message
  ]