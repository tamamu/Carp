module Main where

import Control.Monad
import Control.Monad.IO.Class
import Data.List (isPrefixOf)
import System.Console.Haskeline ( getInputLine
                                , InputT
                                , runInputT
                                , Settings(..)
                                , Completion
                                , simpleCompletion
                                , completeWordWithPrev
                                )
import System.Directory (getHomeDirectory)
import qualified System.Environment as SystemEnvironment
import System.IO (stdout)
import System.Info (os)
import qualified Data.Map as Map
import qualified Data.Set as Set
import ColorText
import Obj
import Types
import Commands
import Template
import ArrayTemplates
import Parsing

defaultProject :: Project
defaultProject = Project { projectTitle = "Untitled"
                         , projectIncludes = [SystemInclude "core.h"]
                         , projectCFlags = ["-fPIC"]
                         , projectLibFlags = ["-lm"]
                         , projectFiles = []
                         , projectEchoC = False
                         , projectCarpDir = "./"
                         , projectOutDir = "./out/"
                         , projectPrompt = if os == "darwin" then "鲮 " else "> "
                         , projectCarpSearchPaths = []
                         , projectPrintTypedAST = False
                         }

completeKeywords :: Monad m => String -> String -> m [Completion]
completeKeywords _ word = return $ findKeywords word keywords []
  where
        findKeywords match [] res = res
        findKeywords match (x : xs) res =
          if isPrefixOf match x
            then findKeywords match xs (res ++ [simpleCompletion x])
            else findKeywords match xs res
        keywords = [ "Int" -- we should probably have a list of those somewhere
                   , "Float"
                   , "Double"
                   , "Bool"
                   , "String"
                   , "Char"
                   , "Array"
                   , "Fn"

                   , "def"
                   , "defn"
                   , "let"
                   , "do"
                   , "if"
                   , "while"
                   , "ref"
                   , "address"
                   , "set!"
                   , "the"

                   , "defmacro"
                   , "dynamic"
                   , "quote"
                   , "car"
                   , "cdr"
                   , "cons"
                   , "list"
                   , "array"
                   , "expand"

                   , "deftype"

                   , "register"

                   , "true"
                   , "false"
                   ]


readlineSettings :: Monad m => IO (Settings m)
readlineSettings = do
  home <- getHomeDirectory
  return $ Settings {
    complete = completeWordWithPrev Nothing ['(', ')', '[', ']', ' ', '\t', '\n'] completeKeywords,
    historyFile = Just $ home ++ "/.carp_history",
    autoAddHistory = True
  }

repl :: Context -> String -> InputT IO ()
repl context readSoFar =
  do let prompt = strWithColor Yellow (if null readSoFar then (projectPrompt (contextProj context)) else "     ") -- 鲤 / 鲮
     input <- (getInputLine prompt)
     case input of
        Nothing -> return ()
        Just i -> do
          let concat = readSoFar ++ i ++ "\n"
          case balance concat of
            0 -> do let input' = if concat == "\n" then contextLastInput context else concat
                    context' <- liftIO $ executeString context input' "REPL"
                    repl (context' { contextLastInput = input' }) ""
            _ -> repl context concat

arrayModule :: Env
arrayModule = Env { envBindings = bindings, envParent = Nothing, envModuleName = Just "Array", envUseModules = [], envMode = ExternalEnv }
  where bindings = Map.fromList [ templateNth
                                , templateReplicate
                                , templateRepeat
                                , templateCopyingMap
                                , templateEMap
                                , templateFilter
                                --, templateReduce
                                , templateRange
                                , templateRaw
                                , templateAset
                                , templateAsetBang
                                , templateCount
                                , templatePushBack
                                , templatePopBack
                                , templateDeleteArray
                                , templateCopyArray
                                , templateStrArray
                                , templateSort
                                , templateIndexOf
                                , templateElemCount
                                ]

startingGlobalEnv :: Bool -> Env
startingGlobalEnv noArray =
  Env { envBindings = bindings,
        envParent = Nothing,
        envModuleName = Nothing,
        envUseModules = [(SymPath [] "String")],
        envMode = ExternalEnv
      }
  where bindings = Map.fromList $ [ register "and" (FuncTy [BoolTy, BoolTy] BoolTy)
                                  , register "or" (FuncTy [BoolTy, BoolTy] BoolTy)
                                  , register "not" (FuncTy [BoolTy] BoolTy)
                                  , register "NULL" (VarTy "a")
                                  ] ++ (if noArray then [] else [("Array", Binder (XObj (Mod arrayModule) Nothing Nothing))])

startingTypeEnv :: Env
startingTypeEnv = Env { envBindings = bindings
                      , envParent = Nothing
                      , envModuleName = Nothing
                      , envUseModules = []
                      , envMode = ExternalEnv
                      }
  where bindings = Map.fromList
          $ [ interfaceBinder "copy" (FuncTy [(RefTy (VarTy "a"))] (VarTy "a")) [SymPath ["Array"] "copy"] builtInSymbolInfo
            , interfaceBinder "str" (FuncTy [(VarTy "a")] StringTy) [SymPath ["Array"] "str"] builtInSymbolInfo
              -- TODO: Implement! ("=", Binder (defineInterface "=" (FuncTy [(VarTy "a"), (VarTy "a")] BoolTy)))
            ]
        builtInSymbolInfo = Info (-1) (-1) "Built-in." Set.empty (-1)

interfaceBinder :: String -> Ty -> [SymPath] -> Info -> (String, Binder)
interfaceBinder name t paths i = (name, Binder (defineInterface name t paths (Just i)))

coreModules :: String -> [String]
coreModules carpDir = map (\s -> carpDir ++ "/core/" ++ s ++ ".carp") [ "Interfaces"
                                                                      , "Macros"
                                                                      , "Int"
                                                                      , "Long"
                                                                      , "Double"
                                                                      , "Float"
                                                                      , "Array"
                                                                      , "String"
                                                                      , "Char"
                                                                      , "Bool"
                                                                      , "IO"
                                                                      , "System"
                                                                      ]

-- | Other options for how to run the compiler
data OtherOptions = NoCore | LogMemory deriving (Show, Eq)

-- | Parse the arguments sent to the compiler from the terminal
parseArgs :: [String] -> ([FilePath], ExecutionMode, [OtherOptions])
parseArgs args = parseArgsInternal [] Repl [] args
  where parseArgsInternal filesToLoad execMode otherOptions [] =
          (filesToLoad, execMode, otherOptions)
        parseArgsInternal filesToLoad execMode otherOptions (arg:restArgs) =
          case arg of
            "-b" -> parseArgsInternal filesToLoad Build otherOptions restArgs
            "-x" -> parseArgsInternal filesToLoad BuildAndRun otherOptions restArgs
            "--no-core" -> parseArgsInternal filesToLoad execMode (NoCore : otherOptions) restArgs
            "--log-memory" -> parseArgsInternal filesToLoad execMode (LogMemory : otherOptions) restArgs
            file -> parseArgsInternal (filesToLoad ++ [file]) execMode otherOptions restArgs

main :: IO ()
main = do putStrLn "Welcome to Carp 0.2.0"
          putStrLn "This is free software with ABSOLUTELY NO WARRANTY."
          putStrLn "Evaluate (help) for more information."
          args <- SystemEnvironment.getArgs
          sysEnv <- SystemEnvironment.getEnvironment
          let (argFilesToLoad, execMode, otherOptions) = parseArgs args
              logMemory = LogMemory `elem` otherOptions
              projectWithFiles = defaultProject { projectFiles = argFilesToLoad
                                                , projectCFlags = (if logMemory then ["-D LOG_MEMORY"] else []) ++
                                                                  (projectCFlags defaultProject)
                                                }
              noCore = NoCore `elem` otherOptions
              noArray = False
              coreModulesToLoad = if noCore then [] else (coreModules (projectCarpDir projectWithCarpDir))
              projectWithCarpDir = case lookup "CARP_DIR" sysEnv of
                                     Just carpDir -> projectWithFiles { projectCarpDir = carpDir }
                                     Nothing -> projectWithFiles
          context <- foldM executeCommand (Context
                                            (startingGlobalEnv noArray)
                                            (TypeEnv startingTypeEnv)
                                            []
                                            projectWithCarpDir
                                            ""
                                            execMode)
                                          (map Load coreModulesToLoad)
          context' <- foldM executeCommand context (map Load argFilesToLoad)
          settings <- readlineSettings
          case execMode of
            Repl -> runInputT settings (repl context' "")
            Build -> do _ <- executeString context' ":b" "Compiler (Build)"
                        return ()
            BuildAndRun -> do _ <- executeString context' ":bx" "Compiler (Build & Run)"
                              -- TODO: Handle the return value from executeString and return that one to the shell
                              return ()
