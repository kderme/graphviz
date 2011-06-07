{-# LANGUAGE OverloadedStrings #-}
{-# OPTIONS_HADDOCK hide #-}

{- |
   Module      : Data.GraphViz.Types.Common
   Description : Common internal functions for dealing with overall types.
   Copyright   : (c) Ivan Lazar Miljenovic
   License     : 3-Clause BSD-style
   Maintainer  : Ivan.Miljenovic@gmail.com

   This module provides common functions used by both
   "Data.GraphViz.Types" as well as "Data.GraphViz.Types.Generalised".
-}
module Data.GraphViz.Types.Common where

import Data.GraphViz.Parsing
import Data.GraphViz.Printing
import Data.GraphViz.Util
import Data.GraphViz.Attributes( Attributes, Attribute(HeadPort, TailPort)
                               , usedByGraphs, usedByClusters
                               , usedByNodes, usedByEdges)
import Data.GraphViz.Attributes.Internal(PortPos, parseEdgeBasedPP)
import Data.GraphViz.State(setDirectedness, getDirectedness, getsGS, modifyGS)

import Data.Maybe(isJust)
import qualified Data.Text.Lazy as T
import Data.Text.Lazy(Text)
import Control.Monad(liftM, liftM2, when)

-- -----------------------------------------------------------------------------
-- This is re-exported by Data.GraphViz.Types

-- | A polymorphic type that covers all possible ID values allowed by
--   Dot syntax.  Note that whilst the 'ParseDot' and 'PrintDot'
--   instances for 'String' will properly take care of the special
--   cases for numbers, they are treated differently here.
data GraphID = Str Text
             | Int Int
             | Dbl Double
             deriving (Eq, Ord, Show, Read)

instance PrintDot GraphID where
  unqtDot (Str str) = unqtDot str
  unqtDot (Int i)   = unqtDot i
  unqtDot (Dbl d)   = unqtDot d

  toDot (Str str) = toDot str
  toDot gID       = unqtDot gID

instance ParseDot GraphID where
  parseUnqt = liftM stringNum parseUnqt

  parse = liftM stringNum parse
          `adjustErr`
          (++ "\nNot a valid GraphID")

stringNum     :: Text -> GraphID
stringNum str = maybe checkDbl Int $ stringToInt str
  where
    checkDbl = if isNumString str
               then Dbl $ toDouble str
               else Str str

-- -----------------------------------------------------------------------------

-- Re-exported by Data.GraphViz.Types and Data.GraphViz.Types.Generalised

-- | Represents a list of top-level list of 'Attribute's for the
--   entire graph/sub-graph.  Note that 'GraphAttrs' also applies to
--   'DotSubGraph's.
--
--   Note that Dot allows a single 'Attribute' to be listen on a line;
--   if this is the case then when parsing, the type of 'Attribute' it
--   is determined and that type of 'GlobalAttribute' is created.
data GlobalAttributes = GraphAttrs { attrs :: Attributes }
                      | NodeAttrs  { attrs :: Attributes }
                      | EdgeAttrs  { attrs :: Attributes }
                      deriving (Eq, Ord, Show, Read)

instance PrintDot GlobalAttributes where
  -- Can't use printAttrBased because an empty list still must be printed.
  unqtDot ga = printGlobAttrType ga <+> toDot (attrs ga) <> semi

  unqtListToDot = printAttrBasedList printGlobAttrType attrs

  listToDot = unqtListToDot

printGlobAttrType              :: GlobalAttributes -> DotCode
printGlobAttrType GraphAttrs{} = text "graph"
printGlobAttrType NodeAttrs{}  = text "node"
printGlobAttrType EdgeAttrs{}  = text "edge"

instance ParseDot GlobalAttributes where
  -- Not using parseAttrBased here because we want to force usage of
  -- Attributes.
  parseUnqt = do gat <- parseGlobAttrType
                 as <- whitespace' >> parse
                 return $ gat as
              `onFail`
              liftM determineType parse

  parse = parseUnqt -- Don't want the option of quoting
          `adjustErr`
          (++ "\n\nNot a valid listing of global attributes")

  -- Have to do this manually because of the special case
  parseUnqtList = parseStatements parse

  parseList = parseUnqtList

parseGlobAttrType :: Parse (Attributes -> GlobalAttributes)
parseGlobAttrType = oneOf [ stringRep GraphAttrs "graph"
                          , stringRep NodeAttrs "node"
                          , stringRep EdgeAttrs "edge"
                          ]

determineType :: Attribute -> GlobalAttributes
determineType attr
  | usedByGraphs attr   = GraphAttrs attr'
  | usedByClusters attr = GraphAttrs attr' -- Also covers SubGraph case
  | usedByNodes attr    = NodeAttrs attr'
  | otherwise           = EdgeAttrs attr' -- Must be for edges.
  where
    attr' = [attr]

-- -----------------------------------------------------------------------------

-- | A node in 'DotGraph'.
data DotNode a = DotNode { nodeID :: a
                         , nodeAttributes :: Attributes
                         }
               deriving (Eq, Ord, Show, Read)

instance (PrintDot a) => PrintDot (DotNode a) where
  unqtDot = printAttrBased printNodeID nodeAttributes

  unqtListToDot = printAttrBasedList printNodeID nodeAttributes

  listToDot = unqtListToDot

printNodeID :: (PrintDot a) => DotNode a -> DotCode
printNodeID = toDot . nodeID

instance (ParseDot a) => ParseDot (DotNode a) where
  parseUnqt = parseAttrBased parseNodeID

  parse = parseUnqt -- Don't want the option of quoting

  parseUnqtList = parseAttrBasedList parseNodeID

  parseList = parseUnqtList

parseNodeID :: (ParseDot a) => Parse (Attributes -> DotNode a)
parseNodeID = liftM DotNode parseAndCheck
  where
    parseAndCheck = do a <- parse
                       me <- optional parseUnwanted
                       maybe (return a) (const notANode) me
    notANode = fail "This appears to be an edge, not a node"
    parseUnwanted = oneOf [ parseEdgeType >> return ()
                          , character ':' >> return () -- PortPos value
                          ]

instance Functor DotNode where
  fmap f n = n { nodeID = f $ nodeID n }

-- -----------------------------------------------------------------------------

-- This is re-exported in Data.GraphViz.Types; defined here so that
-- Generalised can access and use parseEdgeLine (needed for "a -> b ->
-- c"-style edge statements).

-- | An edge in 'DotGraph'.
data DotEdge a = DotEdge { edgeFromNodeID :: a
                         , edgeToNodeID   :: a
                         , edgeAttributes :: Attributes
                         }
               deriving (Eq, Ord, Show, Read)

instance (PrintDot a) => PrintDot (DotEdge a) where
  unqtDot = printAttrBased printEdgeID edgeAttributes

  unqtListToDot = printAttrBasedList printEdgeID edgeAttributes

  listToDot = unqtListToDot

printEdgeID   :: (PrintDot a) => DotEdge a -> DotCode
printEdgeID e = do isDir <- getDirectedness
                   toDot (edgeFromNodeID e)
                     <+> bool undirEdge' dirEdge' isDir
                     <+> toDot (edgeToNodeID e)


instance (ParseDot a) => ParseDot (DotEdge a) where
  parseUnqt = parseAttrBased parseEdgeID

  parse = parseUnqt -- Don't want the option of quoting

  -- Have to take into account edges of the type "n1 -> n2 -> n3", etc.
  parseUnqtList = liftM concat
                  $ parseStatements parseEdgeLine

  parseList = parseUnqtList

parseEdgeID :: (ParseDot a) => Parse (Attributes -> DotEdge a)
parseEdgeID = do eFrom <- parseEdgeNode
                 -- Parse both edge types just to be more liberal
                 parseEdgeType
                 eTo <- parseEdgeNode
                 return $ mkEdge eFrom eTo

type EdgeNode a = (a, Maybe PortPos)

-- | Takes into account edge statements containing something like
--   @a -> \{b c\}@.
parseEdgeNodes :: (ParseDot a) => Parse [EdgeNode a]
parseEdgeNodes = parseBraced ( wrapWhitespace
                               -- Should really use sepBy1, but this will do.
                               $ parseStatements parseEdgeNode
                             )
                 `onFail`
                 liftM return parseEdgeNode

parseEdgeNode :: (ParseDot a) => Parse (EdgeNode a)
parseEdgeNode = liftM2 (,) parse
                           (optional $ character ':' >> parseEdgeBasedPP)

mkEdge :: EdgeNode a -> EdgeNode a
          -> Attributes -> DotEdge a
mkEdge (eFrom, mFP) (eTo, mTP) = DotEdge eFrom eTo
                                 . addPortPos TailPort mFP
                                 . addPortPos HeadPort mTP

mkEdges :: [EdgeNode a] -> [EdgeNode a]
           -> Attributes -> [DotEdge a]
mkEdges fs ts as = liftM2 (\f t -> mkEdge f t as) fs ts

addPortPos   :: (PortPos -> Attribute) -> Maybe PortPos
                -> Attributes -> Attributes
addPortPos c = maybe id ((:) . c)

parseEdgeType :: Parse Bool
parseEdgeType = wrapWhitespace $ stringRep True dirEdge
                                 `onFail`
                                 stringRep False undirEdge

parseEdgeLine :: (ParseDot a) => Parse [DotEdge a]
parseEdgeLine = do n1 <- parseEdgeNodes
                   ens <- many1 $ do parseEdgeType
                                     parseEdgeNodes
                   let ens' = n1 : ens
                       efs = zipWith mkEdges ens' (tail ens')
                       ef = return $ \ as -> concatMap ($as) efs
                   parseAttrBased ef

instance Functor DotEdge where
  fmap f e = e { edgeFromNodeID = f $ edgeFromNodeID e
               , edgeToNodeID   = f $ edgeToNodeID e
               }

dirEdge :: String
dirEdge = "->"

dirEdge' :: DotCode
dirEdge' = text $ T.pack dirEdge

undirEdge :: String
undirEdge = "--"

undirEdge' :: DotCode
undirEdge' = text $ T.pack undirEdge

-- -----------------------------------------------------------------------------
-- Labels

dirGraph :: String
dirGraph = "digraph"

dirGraph' :: DotCode
dirGraph' = text $ T.pack dirGraph

undirGraph :: String
undirGraph = "graph"

undirGraph' :: DotCode
undirGraph' = text $ T.pack undirGraph

strGraph :: String
strGraph = "strict"

strGraph' :: DotCode
strGraph' = text $ T.pack strGraph

sGraph :: String
sGraph = "subgraph"

sGraph' :: DotCode
sGraph' = text $ T.pack sGraph

clust :: String
clust = "cluster"

clust' :: DotCode
clust' = text $ T.pack clust

-- -----------------------------------------------------------------------------

printGraphID                 :: (a -> Bool) -> (a -> Bool)
                                -> (a -> Maybe GraphID)
                                -> a -> DotCode
printGraphID str isDir mID g = do setDirectedness isDir'
                                  bool empty strGraph' (str g)
                                    <+> bool undirGraph' dirGraph' isDir'
                                    <+> maybe empty toDot (mID g)
  where
    isDir' = isDir g

parseGraphID   :: (Bool -> Bool -> Maybe GraphID -> a) -> Parse a
parseGraphID f = do allWhitespace'
                    str <- liftM isJust
                           $ optional (parseAndSpace $ string strGraph)
                    dir <- parseAndSpace ( stringRep True dirGraph
                                           `onFail`
                                           stringRep False undirGraph
                                         )
                    setDirectedness dir
                    gID <- optional $ parseAndSpace parse
                    return $ f str dir gID

printStmtBased          :: (a -> DotCode) -> (a -> b) -> (b -> DotCode)
                           -> a -> DotCode
printStmtBased f r dr a = do gs <- getsGS id
                             dc <- printBracesBased (f a) (dr $ r a)
                             modifyGS (const gs)
                             return dc

printStmtBasedList        :: (a -> DotCode) -> (a -> b) -> (b -> DotCode)
                             -> [a] -> DotCode
printStmtBasedList f r dr = vcat . mapM (printStmtBased f r dr)

parseStmtBased :: Parse stmt -> Parse (stmt -> a) -> Parse a
parseStmtBased = flip apply . parseBracesBased

-- Can't use the 'braces' combinator here because we want the closing
-- brace lined up with the h value, which due to indentation might not
-- be the case with braces.
printBracesBased     :: DotCode -> DotCode -> DotCode
printBracesBased h i = vcat $ sequence [ h <+> lbrace
                                       , ind i
                                       , rbrace
                                       ]
  where
    ind = indent 4

-- | This /must/ only be used for sub-graphs, etc.
parseBracesBased   :: Parse a -> Parse a
parseBracesBased p = do gs <- getsGS id
                        a <- whitespace' >> parseBraced (wrapWhitespace p)
                        modifyGS (const gs)
                        return a
                     `adjustErr`
                     (++ "\nNot a valid value wrapped in braces.")

printSubGraphID     :: (a -> (Bool, Maybe GraphID)) -> a -> DotCode
printSubGraphID f a = sGraph'
                      <+> maybe cl dtID mID
  where
    (isCl, mID) = f a
    cl = bool empty clust' isCl
    dtID = printSGID isCl

-- | Print the actual ID for a 'DotSubGraph'.
printSGID          :: Bool -> GraphID -> DotCode
printSGID isCl sID = bool noClust addClust isCl
  where
    noClust = toDot sID
    -- Have to manually render it as we need the un-quoted form.
    addClust = toDot . T.append (T.pack clust) . T.cons '_'
               . renderDot $ mkDot sID
    mkDot (Str str) = text str -- Quotes will be escaped later
    mkDot gid       = unqtDot gid

parseSubGraphID   :: (Bool -> Maybe GraphID -> c) -> Parse c
parseSubGraphID f = do string sGraph
                       whitespace
                       liftM (uncurry f) parseSGID

parseSGID :: Parse (Bool, Maybe GraphID)
parseSGID = oneOf [ liftM getClustFrom $ parseAndSpace parse
                  , return (False, Nothing)
                  ]
  where
    -- If it's a String value, check to see if it's actually a
    -- cluster_Blah value; thus need to manually re-parse it.
    getClustFrom (Str str) = runParser' pStr str
    getClustFrom gid       = (False, Just gid)

    checkCl = stringRep True clust
    pStr = do isCl <- checkCl
                      `onFail`
                      return False
              when isCl $ optional (character '_') >> return ()
              sID <- optional pID
              let sID' = if sID == emptyID
                         then Nothing
                         else sID
              return (isCl, sID')

    emptyID = Just $ Str ""

    -- For Strings, there are no more quotes to unescape, so consume
    -- what you can.
    pID = liftM stringNum $ manySatisfy (const True)

{- This is a much nicer definition, but unfortunately it doesn't work.
   The problem is that Graphviz decides that a subgraph is a cluster
   if the ID starts with "cluster" (no quotes); thus, we _have_ to do
   the double layer of parsing to get it to work :@

            do isCl <- stringRep True clust
                       `onFail`
                       return False
               sID <- optional $ do when isCl
                                      $ optional (character '_') >> return ()
                                    parseUnqt
               when (isCl || isJust sID) $ whitespace >> return ()
               return (isCl, sID)
-}

printAttrBased          :: (a -> DotCode) -> (a -> Attributes) -> a -> DotCode
printAttrBased ff fas a = dc <> semi
  where
    f = ff a
    dc = case fas a of
           [] -> f
           as -> f <+> toDot as

printAttrBasedList        :: (a -> DotCode) -> (a -> Attributes)
                             -> [a] -> DotCode
printAttrBasedList ff fas = vcat . mapM (printAttrBased ff fas)

parseAttrBased   :: Parse (Attributes -> a) -> Parse a
parseAttrBased p = do f <- p
                      atts <- tryParseList' (whitespace' >> parse)
                      return $ f atts
                   `adjustErr`
                   (++ "\n\nNot a valid attribute-based structure")

parseAttrBasedList :: Parse (Attributes -> a) -> Parse [a]
parseAttrBasedList = parseStatements . parseAttrBased

-- | Parse the separator (and any other whitespace present) between statements.
statementEnd :: Parse ()
statementEnd = parseSplit >> newline'
  where
    parseSplit = (whitespace' >> oneOf [ character ';' >> return ()
                                       , newline
                                       ]
                 )
                 `onFail`
                 whitespace

parseStatements   :: Parse a -> Parse [a]
parseStatements p = sepBy (whitespace' >> p) statementEnd
                    `discard`
                    optional statementEnd
