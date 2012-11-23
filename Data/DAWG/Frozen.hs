{-# LANGUAGE RecordWildCards #-}

-- | The module implements /directed acyclic word graphs/ (DAWGs) internaly
-- represented as /minimal acyclic deterministic finite-state automata/.
--
-- In comparison to "Data.DAWG" module the automaton implemented here:
--
--   * Keeps all nodes in one array and therefore uses much less memory,
--
--   * Constitutes a /perfect hash automaton/ with 'hash' and
--     'unHash' functions,
--
--   * Doesn't provide insert/delete family of operations.

module Data.DAWG.Frozen
(
-- * DAWG type
  DAWG
-- * Query
, lookup
, numStates
-- -- * Index
-- , index
-- , byIndex
-- -- ** Hashing
-- , hash
-- , unHash
-- * Construction
, empty
, fromList
, fromListWith
, fromLang
, weigh
-- * Conversion
, assocs
, keys
, elems
, freeze
) where

import Prelude hiding (lookup)
import Control.Applicative ((<$), (<$>), (<*>))
import Control.Arrow (first, second)
import Data.Binary (Binary, put, get)
import Data.Vector.Binary ()
import Data.Vector.Unboxed (Unbox)
import qualified Data.IntMap as M
import qualified Data.Vector as V

import qualified Data.DAWG.VMap as VM
import qualified Data.DAWG.Internal as I
import qualified Data.DAWG as D

-- | Node identifier.
type Id = Int

-- | Internal representation of the transition symbol.
type Sym = Int

-- | Edge with label.
type Edge a = (Id, a)

to :: Edge a -> Id
to = fst
{-# INLINE to #-}

label :: a -> Edge b -> Edge a
label x (i, y) = (i, x)
{-# INLINE label #-}

withLabel :: a -> Id -> Edge a
withLabel x i = (i, x)
{-# INLINE withLabel #-}

-- | State (node) of the automaton.
data Node a b = Node {
    -- | Value kept in the node.
      value     :: !a
    -- | Labeled edges outgoing from the node.
    , edgeMap   :: !(VM.VMap (Edge b)) }
    deriving (Show, Eq, Ord)

instance (Unbox b, Binary a, Binary b) => Binary (Node a b) where
    put Node{..} = put value >> put edgeMap
    get = Node <$> get <*> get

-- | Transition function.
onSym :: Unbox b => Sym -> Node a b -> Maybe (Edge b)
onSym x (Node _ es) = VM.lookup x es
{-# INLINE onSym #-}

-- List of symbol/edge pairs outgoing from the node.
trans :: Unbox b => Node a b -> [(Sym, Edge b)]
trans = VM.toList . edgeMap
{-# INLINE trans #-}

-- | List of outgoing edges.
edges :: Unbox b => Node a b -> [Edge b]
edges = map snd . trans
{-# INLINE edges #-}

-- | List children identifiers.
children :: Unbox b => Node a b -> [Id]
children = map to . edges
{-# INLINE children #-}

-- | @DAWG a b c@ constitutes an automaton with @a@ transition
-- symbols, @Maybe b@ values stored in nodes and edges labeled
-- with @c@ values.  Root is stored on the first position of
-- the array.
type DAWG a b c = V.Vector (Node (Maybe b) c)

-- | Empty DAWG.
empty :: Unbox c => DAWG a b c
empty = V.singleton (Node Nothing VM.empty)

-- | Number of states in the automaton.
numStates :: DAWG a b c -> Int
numStates = V.length

-- | Node with the given identifier.
nodeBy :: Id -> DAWG a b c -> Node (Maybe b) c
nodeBy i d = d V.! i

-- | Find value associated with the key.
lookup :: (Unbox c, Enum a) => [a] -> DAWG a b c -> Maybe b
lookup xs' =
    let xs = map fromEnum xs'
    in  lookup'I xs 0
{-# SPECIALIZE lookup :: Unbox c => String -> DAWG Char b c -> Maybe b #-}

lookup'I :: Unbox c => [Sym] -> Id -> DAWG a b c -> Maybe b
lookup'I []     i d = value (nodeBy i d)
lookup'I (x:xs) i d = case onSym x (nodeBy i d) of
    Just e  -> lookup'I xs (to e) d
    Nothing -> Nothing

-- | Return all key/value pairs in the DAWG in ascending key order.
assocs :: (Enum a, Unbox c) => DAWG a b c -> [([a], b)]
assocs d = map (first (map toEnum)) (assocs'I 0 d)
{-# SPECIALIZE assocs :: Unbox c => DAWG Char b c -> [(String, b)] #-}

assocs'I :: Unbox c => Id -> DAWG a b c -> [([Sym], b)]
assocs'I i d =
    here ++ concatMap there (trans n)
  where
    n = nodeBy i d
    here = case value n of
        Just x  -> [([], x)]
        Nothing -> []
    there (x, e) = map (first (x:)) (assocs'I (to e) d)

-- | Return all keys of the DAWG in ascending order.
keys :: (Unbox c, Enum a) => DAWG a b c -> [[a]]
keys = map fst . assocs
{-# SPECIALIZE keys :: Unbox c => DAWG Char b c -> [String] #-}

-- | Return all elements of the DAWG in the ascending order of their keys.
elems :: Unbox c => DAWG a b c -> [b]
elems = map snd . assocs'I 0

-- | Construct 'DAWG' from the list of (word, value) pairs.
-- First a 'D.DAWG' is created and then it is frozen using
-- the 'freeze' function.
fromList :: (Enum a, Ord b) => [([a], b)] -> DAWG a b ()
fromList = freeze . D.fromList
{-# SPECIALIZE fromList :: Ord b => [(String, b)] -> DAWG Char b () #-}

-- | Construct DAWG from the list of (word, value) pairs
-- with a combining function.  The combining function is
-- applied strictly. First a 'D.DAWG' is created and then
-- it is frozen using the 'freeze' function.
fromListWith :: (Enum a, Ord b) => (b -> b -> b) -> [([a], b)] -> DAWG a b ()
fromListWith f = freeze . D.fromListWith f
{-# SPECIALIZE fromListWith :: Ord b => (b -> b -> b)
        -> [(String, b)] -> DAWG Char b () #-}

-- | Make DAWG from the list of words.  Annotate each word with
-- the @()@ value.  First a 'D.DAWG' is created and then it is frozen
-- using the 'freeze' function.
fromLang :: Enum a => [[a]] -> DAWG a () ()
fromLang = freeze . D.fromLang
{-# SPECIALIZE fromLang :: [String] -> DAWG Char () () #-}

-- | Weight of the node corresponds to the number of final states
-- reachable from the node.  Weight of the edge is a sum of the
-- weight of the node the edge points to and weights of preceding
-- edges outgoing from the same parent node.
type Weight = Int

-- | Recursively compute node weights and store corresponding values
-- in transition labels.
weigh :: Unbox c => DAWG a b c -> DAWG a b Weight
-- weigh d = V.fromList
--     [ (nodeBy i d) { size = nodeWeight i }
--     | i <- [0 .. numStates d - 1] ]
weigh d = V.fromList
    [ Node (value n) (apply ws (trans n))
    | i <- [0 .. numStates d - 1]
    , let n  = nodeBy i d
    , let ws = accum (children n) ]
  where
    -- In nodeWeight node weights are memoized.
    nodeWeight = ((V.!) . V.fromList) (map detWeight [0 .. numStates d - 1])
    -- Determine weight of the node.
    detWeight i =
        let n = nodeBy i d
            js = children n
        in  add (value n) (map nodeWeight js)
    add w x = maybe 0 (const 1) w + sum x
    -- Weight for subsequent edges.
    accum = tail . scanl (+) 0 . map nodeWeight
    -- Apply weight to edges. 
    apply ws ts = VM.fromList
        [ (x, label w e)
        | (w, (x, e)) <- zip ws ts ]

-- | Yield immutable version of the automaton.
freeze :: D.DAWG a b -> DAWG a b ()
freeze d = V.fromList $
    map (stop . oldBy) (M.elems (inverse old2new))
  where
    -- Map from old to new identifiers.
    old2new :: M.IntMap Int
    old2new = M.fromList $ (D.root d, 0) : zip (nodeIDs d) [1..]
    -- List of non-frozen branches' IDs without the root ID.
    nodeIDs = filter (/= D.root d) . branchIDs
    -- Make frozen node with new IDs from non-frozen node.
    stop    = Node <$> onEps <*> mkEdges . I.edgeMap
    -- Extract value following the epsilon transition.
    onEps   = I.unValue . oldBy . I.eps
    -- List of edges with new IDs.
    mkEdges = VM.fromList . map (second mkEdge) . VM.toList 
    -- Make edge from old ID.
    mkEdge = withLabel () . (old2new M.!)
    -- Non-frozen node by given identifier.
    oldBy i = I.nodeBy i (D.graph d)

-- | Branch IDs in the non-frozen DAWG.
branchIDs :: D.DAWG a b -> [I.Id]
branchIDs
    = map fst . filter (isBranch . snd)
    . M.assocs . I.nodeMap . D.graph
  where
    isBranch (I.Branch _ _) = True
    isBranch _              = False
        
-- | Inverse of the map.
inverse :: M.IntMap Int -> M.IntMap Int
inverse =
    let swap (x, y) = (y, x)
    in  M.fromList . map swap . M.toList

-- -- | Yield a 'D.DAWG' version of the automaton.
-- thaw :: DAWG a b -> D.DAWG a b
-- thaw d =
--     D.DAWG graph 0
--   where
--     graph = I.Graph
--         (Map.fromList $ zip nodes [0..])
--         IS.empty
--         (M.fromList   $ zip [0..] nodes)
--         (

-- -- | Position in a set of all dictionary entries with respect
-- -- to the lexicographic order.
-- index :: Enum a => [a] -> DAWG a b -> Maybe Int
-- index xs = index'I (map fromEnum xs) 0
-- {-# SPECIALIZE index :: String -> DAWG Char b -> Maybe Int #-}
-- 
-- index'I :: [Int] -> Id -> DAWG a b -> Maybe Int
-- index'I []     i d = 0 <$ value (nodeBy i d)
-- index'I (x:xs) i d = case onSym x n of
--     Just j  -> do
--         x0 <- index'I xs j d
--         let x1 = maybe 0 (const 1) (value n)
--                + (sum . map sizeBy) (before (x, j))
--         return $ x0 + x1
--     Nothing -> Nothing
--   where
--     -- Current node.
--     n = nodeBy i d
--     -- Size of node by ID.
--     sizeBy = size . flip nodeBy d
--     -- All childresn IDs before the (x, j) edge.
--     before e = map snd . fst $ span (/=e) (edgeList n)
-- 
-- -- | Perfect hashing function for dictionary entries.
-- -- A synonym for the 'index' function.
-- hash :: Enum a => [a] -> DAWG a b -> Maybe Int
-- hash = index
-- {-# INLINE hash #-}
-- 
-- -- | Find dictionary entry given its index with respect to the
-- -- lexicographic order.
-- byIndex :: Enum a => Int -> DAWG a b -> Maybe [a]
-- byIndex i d = map toEnum <$> byIndex'I i 0 d
-- {-# SPECIALIZE byIndex :: Int -> DAWG Char b -> Maybe String #-}
-- 
-- byIndex'I :: Int -> Id -> DAWG a b -> Maybe [Int]
-- byIndex'I ix i d = do
--     (acc, x, j) <- findChild 0 (edgeList n)
--     xs <- byIndex'I (ix - acc) j d
--     return (x:xs)
--   where
--     -- Current node.
--     n   = nodeBy i d
--     -- Size of node by ID.
--     sizeBy = size . flip nodeBy d
--     -- Sum node size values and find the appropriate one.
--     findChild acc ((x, j) : js)
--         | acc < ix  = findChild (acc + sizeBy j) js
--         | otherwise = Just (acc, x, j)
--     findChild _ []  = Nothing
-- 
-- -- | Inverse of the 'hash' function and a synonym for the 'byIndex' function.
-- unHash :: Enum a => Int -> DAWG a b -> Maybe [a]
-- unHash = byIndex
-- {-# INLINE unHash #-}
