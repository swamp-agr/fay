{-# OPTIONS -fno-warn-orphans           #-}
{-# LANGUAGE DeriveDataTypeable         #-}
{-# LANGUAGE FunctionalDependencies     #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE MultiParamTypeClasses      #-}
{-# LANGUAGE OverloadedStrings          #-}
{-# LANGUAGE RecordWildCards            #-}
{-# LANGUAGE TypeSynonymInstances       #-}
{-# LANGUAGE FlexibleInstances          #-}
{-# LANGUAGE ViewPatterns               #-}
{-# LANGUAGE TypeFamilies               #-}

-- | All Fay types and instances.

module Fay.Types
  (JsStmt(..)
  ,JsExp(..)
  ,JsLit(..)
  ,JsName(..)
  ,CompileError(..)
  ,Compile(..)
  ,AllTheState
  ,Compile2
  ,CompilesTo(..)
  ,Printable(..)
  ,Fay
  ,CompileReader(..)
  ,CompileWriter(..)
  ,CompileConfig(..)
  ,CompileState(..)
  ,addCurrentExport
  ,getCurrentExports
  ,getNonLocalExports
  ,getCurrentExportsWithoutNewtypes
  ,getExportsFor
  ,faySourceDir
  ,FundamentalType(..)
  ,PrintState(..)
  ,Printer(..)
  ,Mapping(..)
  ,SerializeContext(..)
  ,ModulePath (unModulePath)
  ,mkModulePath
  ,mkModulePaths
  ,mkModulePathFromQName
  ,addModulePath
  ,addedModulePath
  ) where
import           Control.Applicative
import           Control.Monad.Error    (Error, ErrorT, MonadError)
import           Control.Monad.Identity (Identity)
import           Control.Monad.State
import           Control.Monad.RWS
import           Data.Default
import           Data.List
import           Data.List.Split
import           Data.Maybe
import           Data.Map              (Map)
import qualified Data.Map              as M
import           Data.Set              (Set)
import qualified Data.Set              as S
import           Data.String
import qualified Fay.Exts as F
import qualified Fay.Exts.Scoped as S
import qualified Fay.Exts.NoAnnotation as N
import Fay.Exts.NoAnnotation (unAnn)
import Language.Haskell.Exts.Annotated
import Language.Haskell.Names (Symbols)
import Distribution.HaskellSuite.Modules
import           Fay.Compiler.ModuleScope (ModuleScope)
import           Fay.Compiler.QName
import           Paths_fay

--------------------------------------------------------------------------------
-- Compiler types

-- | Configuration of the compiler.
data CompileConfig = CompileConfig
  { configOptimize           :: Bool                       -- ^ Run optimizations
  , configFlattenApps        :: Bool                       -- ^ Flatten function application?
  , configExportBuiltins     :: Bool                       -- ^ Export built-in functions?
  , configExportRuntime      :: Bool                       -- ^ Export the runtime?
  , configExportStdlib       :: Bool                       -- ^ Export the stdlib?
  , configExportStdlibOnly   :: Bool                       -- ^ Export /only/ the stdlib?
  , configDirectoryIncludes :: [(Maybe String, FilePath)]  -- ^ Possibly a fay package name, and a include directory.
  , configPrettyPrint        :: Bool                       -- ^ Pretty print the JS output?
  , configHtmlWrapper        :: Bool                       -- ^ Output a HTML file including the produced JS.
  , configHtmlJSLibs         :: [FilePath]                 -- ^ Any JS files to link to in the HTML.
  , configLibrary            :: Bool                       -- ^ Don't invoke main in the produced JS.
  , configWarn               :: Bool                       -- ^ Warn on dubious stuff, not related to typechecking.
  , configFilePath           :: Maybe FilePath             -- ^ File path to output to.
  , configTypecheck          :: Bool                       -- ^ Typecheck with GHC.
  , configWall               :: Bool                       -- ^ Typecheck with -Wall.
  , configGClosure           :: Bool                       -- ^ Run Google Closure on the produced JS.
  , configPackageConf        :: Maybe FilePath             -- ^ The package config e.g. packages-6.12.3.
  , configPackages           :: [String]                   -- ^ Included Fay packages.
  , configBasePath           :: Maybe FilePath             -- ^ Custom source location for fay-base
  } deriving (Show)

-- | The name of a module split into a list for code generation.
newtype ModulePath = ModulePath { unModulePath :: [String] }
  deriving (Eq, Ord, Show)

-- | Construct the complete ModulePath from a ModuleName.
mkModulePath :: ModuleName a -> ModulePath
mkModulePath (ModuleName _ m) = ModulePath . splitOn "." $ m

-- | Construct intermediate module paths from a ModuleName.
-- mkModulePaths "A.B" => [["A"], ["A","B"]]
mkModulePaths :: ModuleName a -> [ModulePath]
mkModulePaths (ModuleName _ m) = map ModulePath . tail . inits . splitOn "." $ m

-- | Converting a QName to a ModulePath is only relevant for constructors since
-- they can conflict with module names.
mkModulePathFromQName :: QName a -> ModulePath
mkModulePathFromQName (Qual _ (ModuleName _ m) n) = mkModulePath $ ModuleName F.noI $ m ++ "." ++ unname n
mkModulePathFromQName _ = error "mkModulePathFromQName: Not a qualified name"

-- | State of the compiler.
data CompileState = CompileState
  { _stateExports      :: Map N.ModuleName (Set N.QName) -- ^ Collects exports from modules
  , stateRecordTypes   :: [(N.QName,[N.QName])]          -- ^ Map types to constructors
  , stateRecords       :: [(N.QName,[N.QName])]          -- ^ Map constructors to fields
  , stateNewtypes      :: [(N.QName, Maybe N.QName, N.Type)] -- ^ Newtype constructor, destructor, wrapped type tuple
  , stateImported      :: [(N.ModuleName,FilePath)]    -- ^ Map of all imported modules and their source locations.
  , stateNameDepth     :: Integer                    -- ^ Depth of the current lexical scope.
  , stateLocalScope    :: Set N.Name                   -- ^ Names in the current lexical scope.
  , stateModuleScope   :: ModuleScope                -- ^ Names in the module scope.
  , stateModuleScopes  :: Map N.ModuleName ModuleScope
  , stateModuleName    :: N.ModuleName                 -- ^ Name of the module currently being compiled.
  , stateJsModulePaths :: Set ModulePath
  , stateUseFromString :: Bool
  } deriving (Show)

-- | Things written out by the compiler.
data CompileWriter = CompileWriter
  { writerCons     :: [JsStmt] -- ^ Constructors.
  , writerFayToJs  :: [(String,JsExp)] -- ^ Fay to JS dispatchers.
  , writerJsToFay  :: [(String,JsExp)] -- ^ JS to Fay dispatchers.
  }
  deriving (Show)

-- | Simple concatenating instance.
instance Monoid CompileWriter where
  mempty = CompileWriter [] [] []
  mappend (CompileWriter a b c) (CompileWriter x y z) =
    CompileWriter (a++x) (b++y) (c++z)

-- | Configuration and globals for the compiler.
data CompileReader = CompileReader
  { readerConfig       :: CompileConfig -- ^ The compilation configuration.
  , readerCompileLit   :: S.Literal -> Compile JsExp
  , readerCompileDecls :: Bool -> [S.Decl] -> Compile [JsStmt]
  }

-- | The data-files source directory.
faySourceDir :: IO FilePath
faySourceDir = getDataFileName "src/"

-- | Add a ModulePath to CompileState, meaning it has been printed.
addModulePath :: ModulePath -> CompileState -> CompileState
addModulePath mp cs = cs { stateJsModulePaths = mp `S.insert` stateJsModulePaths cs }

-- | Has this ModulePath been added/printed?
addedModulePath :: ModulePath -> CompileState -> Bool
addedModulePath mp CompileState{..} = mp `S.member` stateJsModulePaths

-- | Adds a new export to '_stateExports' for the module specified by
-- 'stateModuleName'.
addCurrentExport :: QName a -> CompileState -> CompileState
addCurrentExport (N.unAnn -> q) cs =
    cs { _stateExports = M.insert (stateModuleName cs) qnames $ _stateExports cs }
  where
    qnames = maybe (S.singleton q) (S.insert q)
           $ M.lookup (stateModuleName cs) (_stateExports cs)

-- | Get all exports for the current module.
getCurrentExports :: CompileState -> Set N.QName
getCurrentExports cs = getExportsFor (stateModuleName cs) cs

-- | Get exports from the current module originating from other modules.
getNonLocalExports :: CompileState -> Set N.QName
getNonLocalExports st = S.filter ((/= Just (stateModuleName st)) . qModName) . getCurrentExportsWithoutNewtypes $ st

-- | Get all exports from the current module except newtypes.
getCurrentExportsWithoutNewtypes :: CompileState -> Set N.QName
getCurrentExportsWithoutNewtypes cs = excludeNewtypes cs $ getCurrentExports cs
  where
    excludeNewtypes :: CompileState -> Set N.QName -> Set N.QName
    excludeNewtypes cs' names =
      let newtypes = stateNewtypes cs'
          constrs = map (\(c, _, _) -> c) newtypes
          destrs  = map (\(_, d, _) -> fromJust d) . filter (\(_, d, _) -> isJust d) $ newtypes
       in names `S.difference` (S.fromList constrs `S.union` S.fromList destrs)

-- | Get all of the exported identifiers for the given module.
getExportsFor :: ModuleName a -> CompileState -> Set N.QName
getExportsFor (unAnn -> mn) cs = fromMaybe S.empty $ M.lookup mn (_stateExports cs)

-- | Compile monad.
newtype Compile a = Compile
  { unCompile :: (RWST CompileReader
                      CompileWriter
                      CompileState
                      (ErrorT CompileError (ModuleT (ModuleInfo Compile) IO)))
                   a -- ^ Uns the compiler
  }
  deriving (MonadState CompileState
           ,MonadError CompileError
           ,MonadReader CompileReader
           ,MonadWriter CompileWriter
           ,MonadIO
           ,Monad
           ,Functor
           ,Applicative
           )

type AllTheState a = Either CompileError (a, CompileState, CompileWriter)

type Compile2 a = ModuleT Symbols
                          IO
                          (AllTheState a)


--instance MonadReader r m => MonadReader r (ModuleT m) where
--    ask   = lift ask
--    local = mapListT . local
--    reader = lift . reader

instance MonadModule Compile where
  type ModuleInfo Compile = Symbols
  lookupInCache        = lifting . lookupInCache
  insertInCache n m    = lifting $ insertInCache n m
  getPackages          = lifting $ getPackages
  readModuleInfo fps n = lifting $ readModuleInfo fps n

lifting :: ModuleT Symbols IO a -> Compile a
lifting = Compile . lift . lift

-- | Just a convenience class to generalize the parsing/printing of
-- various types of syntax.
class (Parseable from,Printable to) => CompilesTo from to | from -> to where
  compileTo :: from -> Compile to

-- | A source mapping.
data Mapping = Mapping
  { mappingName :: String -- ^ The name of the mapping.
  , mappingFrom :: SrcLoc -- ^ The original source location.
  , mappingTo   :: SrcLoc -- ^ The new source location.
  } deriving (Show)

-- | The state of the pretty printer.
data PrintState = PrintState
  { psPretty       :: Bool      -- ^ Are we to pretty print?
  , psLine         :: Int       -- ^ The current line.
  , psColumn       :: Int       -- ^ Current column.
  , psMapping      :: [Mapping] -- ^ Source mappings.
  , psIndentLevel  :: Int       -- ^ Current indentation level.
  , psOutput       :: [String]  -- ^ The current output. TODO: Make more efficient.
  , psNewline      :: Bool      -- ^ Just outputted a newline?
  }

-- | Default state.
instance Default PrintState where
  def = PrintState False 0 0 [] 0 [] False

-- | The printer monad.
newtype Printer a = Printer { runPrinter :: State PrintState a }
  deriving (Monad,Functor,MonadState PrintState)

-- | Print some value.
class Printable a where
  printJS :: a -> Printer ()

-- | Error type.
data CompileError
  = ParseError S.SrcLoc String
  | UnsupportedDeclaration S.Decl
  | UnsupportedExportSpec N.ExportSpec
  | UnsupportedExpression S.Exp
  | UnsupportedFieldPattern S.PatField
  | UnsupportedImport F.ImportDecl
  | UnsupportedLet
  | UnsupportedLetBinding S.Decl
  | UnsupportedLiteral S.Literal
  | UnsupportedModuleSyntax String F.Module
  | UnsupportedPattern S.Pat
  | UnsupportedQualStmt S.QualStmt
  | UnsupportedRecursiveDo
  | UnsupportedRhs S.Rhs
  | UnsupportedWhereInAlt S.Alt
  | UnsupportedWhereInMatch S.Match
  | EmptyDoBlock
  | InvalidDoBlock
  | Couldn'tFindImport N.ModuleName [FilePath]
  | FfiNeedsTypeSig S.Decl
  | FfiFormatBadChars SrcSpanInfo String
  | FfiFormatNoSuchArg SrcSpanInfo Int
  | FfiFormatIncompleteArg SrcSpanInfo
  | FfiFormatInvalidJavaScript SrcSpanInfo String String
  | UnableResolveQualified N.QName
  | GHCError String
--  | FayScopeError String
  deriving (Show)
instance Error CompileError

-- | The JavaScript FFI interfacing monad.
newtype Fay a = Fay (Identity a)
  deriving Monad

--------------------------------------------------------------------------------
-- JS AST types

-- | Statement type.
data JsStmt
  = JsVar JsName JsExp
  | JsMappedVar SrcLoc JsName JsExp
  | JsIf JsExp [JsStmt] [JsStmt]
  | JsEarlyReturn JsExp
  | JsThrow JsExp
  | JsWhile JsExp [JsStmt]
  | JsUpdate JsName JsExp
  | JsSetProp JsName JsName JsExp
  | JsSetQName N.QName JsExp
  | JsSetModule ModulePath JsExp
  | JsSetConstructor N.QName JsExp
  | JsSetPropExtern JsName JsName JsExp
  | JsContinue
  | JsBlock [JsStmt]
  | JsExpStmt JsExp
  deriving (Show,Eq)

-- | Expression type.
data JsExp
  = JsName JsName
  | JsRawExp String
  | JsSeq [JsExp]
  | JsFun (Maybe JsName) [JsName] [JsStmt] (Maybe JsExp)
  | JsLit JsLit
  | JsApp JsExp [JsExp]
  | JsNegApp JsExp
  | JsTernaryIf JsExp JsExp JsExp
  | JsNull
  | JsParen JsExp
  | JsGetProp JsExp JsName
  | JsLookup JsExp JsExp
  | JsUpdateProp JsExp JsName JsExp
  | JsGetPropExtern JsExp String
  | JsUpdatePropExtern JsExp JsName JsExp
  | JsList [JsExp]
  | JsNew JsName [JsExp]
  | JsThrowExp JsExp
  | JsInstanceOf JsExp JsName
  | JsIndex Int JsExp
  | JsEq JsExp JsExp
  | JsNeq JsExp JsExp
  | JsInfix String JsExp JsExp -- Used to optimize *, /, +, etc
  | JsObj [(String,JsExp)]
  | JsLitObj [(N.Name,JsExp)]
  | JsUndefined
  | JsAnd JsExp JsExp
  | JsOr  JsExp JsExp
  deriving (Show,Eq)

-- | A name of some kind.
data JsName
  = JsNameVar N.QName
  | JsThis
  | JsParametrizedType
  | JsThunk
  | JsForce
  | JsApply
  | JsParam Integer
  | JsTmp Integer
  | JsConstructor N.QName
  | JsBuiltIn N.Name
  | JsModuleName N.ModuleName
  deriving (Eq,Show)

-- | Literal value type.
data JsLit
  = JsChar Char
  | JsStr String
  | JsInt Int
  | JsFloating Double
  | JsBool Bool
  deriving (Show,Eq)

-- | Just handy to have.
instance IsString JsLit where fromString = JsStr

-- | These are the data types that are serializable directly to native
-- JS data types. Strings, floating points and arrays. The others are:
-- actions in the JS monad, which are thunks that shouldn't be forced
-- when serialized but wrapped up as JS zero-arg functions, and
-- unknown types can't be converted but should at least be forced.
data FundamentalType
   -- Recursive types.
 = FunctionType [FundamentalType]
 | JsType FundamentalType
 | ListType FundamentalType
 | TupleType [FundamentalType]
 | UserDefined N.Name [FundamentalType]
 | Defined FundamentalType
 | Nullable FundamentalType
 -- Simple types.
 | DateType
 | StringType
 | DoubleType
 | IntType
 | BoolType
 | PtrType
 --  Automatically serialize this type.
 | Automatic
 -- Unknown.
 | UnknownType
   deriving (Show)

-- | Helpful for some things.
instance IsString N.Name where
  fromString = Ident ()

-- | Helpful for some things.
instance IsString N.QName where
  fromString = UnQual () . Ident ()

-- | Helpful for writing qualified symbols (Fay.*).
instance IsString N.ModuleName where
   fromString = ModuleName ()

-- | The serialization context indicates whether we're currently
-- serializing some value or a particular field in a user-defined data
-- type.
data SerializeContext = SerializeAnywhere | SerializeUserArg Int
  deriving (Read,Show,Eq)
