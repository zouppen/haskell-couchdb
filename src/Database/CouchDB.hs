-- |CouchDB bindings.
module Database.CouchDB 
  ( CouchMonad
  , runCouchDB
  , runCouchDB'
  , createDB
  , dropDB
  , newNamedDoc
  , newDoc
  , updateDoc
  , deleteDoc
  , getDoc
  , getAllDocIds
  , CouchView (..)
  , newView
  , queryView
  , queryViewKeys
  ) where

import System.Log.Logger (errorM)
import Database.CouchDB.HTTP
import Control.Monad
import Control.Monad.Trans (liftIO)
import Data.Maybe (fromJust,mapMaybe)
import Text.JSON

import qualified Data.List as L

couchResponse :: String -> [(String,JSValue)]
couchResponse respBody = case decode respBody of
  Error s -> error s
  Ok r -> fromJSObject r

request' path method = request path [] method [] ""

-- |Creates a new database.  Throws an exception if the database already
-- exists. 
createDB :: String -> CouchMonad ()
createDB name = do
  resp <- request' name PUT
  unless (rspCode resp == (2,0,1)) $
    error (rspReason resp)

dropDB :: String -> CouchMonad Bool -- ^False if the database does not exist
dropDB name = do
  resp <- request' name DELETE
  case rspCode resp of
    (2,0,0) -> return True
    (4,0,4) -> return False
    otherwise -> error (rspReason resp)

newNamedDoc :: (JSON a)
            => String -- ^database name
            -> String -- ^document name
            -> a -- ^document body
            -- |'Left' is a conflict, 'Right' is success
            -> CouchMonad (Either String String)
newNamedDoc dbName docName body = do
  r <- request (dbName ++ "/" ++ docName) [] PUT [] 
               (encode $ showJSON body)
  case rspCode r of
    (2,0,1) -> do
      let result = couchResponse (rspBody r)
      let (JSString rev) = fromJust $ lookup "rev" result
      return (Right $ fromJSString rev)
    (4,0,9) ->  do
      let result = couchResponse (rspBody r)
      let (JSObject errorObj) = fromJust $ lookup "error" result
      let (JSString reason) = 
            fromJust $ lookup "reason" (fromJSObject errorObj)
      return $ Left (fromJSString reason)
    otherwise -> error (show r)

updateDoc :: (JSON a)
          => String -- ^database
          -> (JSString,JSString) -- ^document and revision
          -> a -- ^ new value
          -> CouchMonad (Maybe (JSString,JSString)) 
updateDoc db (doc,rev) val = do
  let (JSObject obj) = showJSON val
  let doc' = fromJSString doc
  let obj' = ("_id",JSString doc):("_rev",JSString rev):(fromJSObject obj)
  r <- request (db ++ "/" ++ doc') [] PUT [] (encode $ toJSObject obj')
  case rspCode r of
    (2,0,1) ->  do
      let result = couchResponse (rspBody r)
      let (JSString rev) = fromJust $ lookup "rev" result
      return $ Just (doc,rev)
    (4,0,9) ->  return Nothing
    otherwise -> 
      error $ "updateDoc error.\n" ++ (show r) ++ rspBody r

deleteDoc :: String  -- ^database
          -> (JSString,JSString) -- ^document and revision
          -> CouchMonad Bool
deleteDoc db (doc,rev) = do 
  r <- request (db ++ "/" ++ (fromJSString doc)) [("rev",fromJSString rev)]
         DELETE [] ""
  case rspCode r of
    (2,0,0) -> return True
    -- TODO: figure out which error codes are normal (delete conflicts)
    otherwise -> fail $ "deleteDoc failed: " ++ (show r)
      

newDoc :: (JSON a)
       => String -- ^database name
      -> a       -- ^document body
      -> CouchMonad (JSString,JSString) -- ^ id and rev of new document
newDoc db doc = do
  r <- request db [] POST [] (encode $ showJSON doc)
  case rspCode r of
    (2,0,1) -> do
      let result = couchResponse (rspBody r)
      let (JSString rev) = fromJust $ lookup "rev" result
      let (JSString id) = fromJust $ lookup "id" result
      return (id,rev)
    otherwise -> error (show r)
    
getDoc :: (JSON a)
       => String -- ^database name
       -> String -- ^document name
       -- |'Nothing' if the doc does not exist
       -> CouchMonad (Maybe (JSString,JSString,a))
getDoc dbName docName = do
  r <- request' (dbName ++ "/" ++ docName) GET
  case rspCode r of
    (2,0,0) -> do
      let result = couchResponse (rspBody r)
      let (JSString rev) = fromJust $ lookup "_rev" result
      let (JSString id) = fromJust $ lookup "_id" result
      case readJSON (JSObject $ toJSObject result) of
        Ok val -> return $ Just (id, rev, val)
        val -> fail $ "error parsing: " ++ encode (toJSObject result)
    (4,0,4) -> return Nothing -- doc does not exist
    otherwise -> error (show r)

allDocRow :: JSValue -> Maybe String
allDocRow (JSObject row) = case lookup "key" (fromJSObject row) of
  Just (JSString s) -> let key = fromJSString s
                         in case key of
                              '_':_ -> Nothing
                              otherwise -> Just key
  Nothing -> error $ "no key in a row " ++ show row
allDocRow v = error $ "expected row to be an object, received " ++ show v

getAllDocIds ::String -- ^database name
             -> CouchMonad [String]
getAllDocIds db = do
  response <- request' (db ++ "/_all_docs") GET
  case rspCode response of
    (2,0,0) -> do
      let result = couchResponse (rspBody response)
      let (JSArray rows) = fromJust $ lookup "rows" result
      return $ mapMaybe allDocRow rows
    otherwise -> error (show response)

--
-- $views
-- Creating and querying views
--

data CouchView = ViewMap String String
               | ViewMapReduce String String String

couchViewToJSON :: CouchView -> (String,JSValue)
couchViewToJSON (ViewMap name fn) = (name,JSObject $ toJSObject fn') where
  fn' = [("map", JSString $ toJSString fn)]
couchViewToJSON (ViewMapReduce name m r) =
  (name, JSObject $ toJSObject obj) where
    obj = [("map", JSString $ toJSString m),
           ("reduce", JSString $ toJSString r)]

newView :: String -- ^database name
        -> String -- ^view set name
        -> [CouchView] -- ^views
        -> CouchMonad ()
newView dbName viewName views = do
  let body = toJSObject 
        [("language", JSString $ toJSString "javascript"),
         ("views", JSObject $ toJSObject (map couchViewToJSON views))]
  result <- newNamedDoc dbName ("_design/" ++ viewName) 
             (JSObject body)
  case result of
    Right _ -> return ()
    Left err -> error err

toRow :: JSON a => JSValue -> (JSString,a)
toRow (JSObject objVal) = (key,value) where
   obj = fromJSObject objVal
   key = case lookup "id" obj of
     Just (JSString s) -> s
     Just v -> error $ "toRow: expected id to be a string, got " ++ show v
     Nothing -> error $ "toRow: row does not have an id field in " 
                        ++ show obj
   value = case lookup "value" obj of
     Just v -> case readJSON v of
       Ok v' -> v'
       Error s -> error s
     Nothing -> error $ "toRow: row does not have a value in " ++ show obj

queryView :: (JSON a)
          => String  -- ^database
          -> String  -- ^design
          -> String  -- ^view
          -> [(String, JSValue)] -- ^query parameters
          -- |Returns a list of rows.  Each row is a key, value pair.
          -> CouchMonad [(JSString, a)]
queryView db viewSet view args = do
  let args' = map (\(k,v) -> (k,encode v)) args
  let url' = concat [db,"/_view/",viewSet,"/",view]
  r <- request url' args' GET [] ""
  case rspCode r of
    (2,0,0) -> do
      let result = couchResponse (rspBody r)
      let (JSArray rows) = fromJust $ lookup "rows" result
      return $ map toRow rows
    otherwise -> error (show r)

-- |Like 'queryView', but only returns the keys.  Use this for key-only
-- views where the value is completely ignored.
queryViewKeys :: String  -- ^database
            -> String  -- ^design
            -> String  -- ^view
            -> [(String, JSValue)] -- ^query parameters
            -> CouchMonad [String]
queryViewKeys db viewSet view args = do
  let args' = map (\(k,v) -> (k,encode v)) args
  let url' = concat [db,"/_view/",viewSet,"/",view]
  r <- request url' args' GET [] ""
  case rspCode r of
    (2,0,0) -> do
      let result = couchResponse (rspBody r)
      case lookup "rows" result of
        Just (JSArray rows) -> liftIO $ mapM rowKey rows
        otherwise -> fail $ "queryView: expected rows"
    otherwise -> error (show r)

rowKey :: JSValue -> IO String
rowKey (JSObject obj) = do
  let assoc = fromJSObject obj
  case lookup "id" assoc of
    Just (JSString s) -> return (fromJSString s)
    v -> fail "expected id"
rowKey v = fail "expected id"
