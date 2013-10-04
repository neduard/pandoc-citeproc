-- Experimental:
-- goes from bibtex to yaml directly, without bibutils
-- properly parses LaTeX bibtex fields, including math
-- does not yet support biblatex fields
-- probably does not support bibtex accurately
module Main where
import Text.BibTeX.Entry
import Text.BibTeX.Parse hiding (identifier, entry)
import Text.Parsec.String
import Text.Parsec hiding (optional, (<|>))
import Control.Applicative
import Text.Pandoc
import qualified Data.Map as M
import Data.Yaml
import Data.List.Split (splitOn, splitWhen)
import Data.List (intersperse)
import Data.Maybe
import Data.Char (toLower, isUpper, isLower)
import System.Console.GetOpt
import System.Environment
import System.Exit
import System.IO (stderr, hPutStrLn)
import Control.Monad
import Control.Monad.RWS.Strict
import Control.Monad.Reader
import System.Environment (getEnvironment)
import qualified Data.Text as T
import Text.CSL.Reference
import Text.CSL.Pandoc (blocksToString, inlinesToString)
import qualified Data.ByteString as B

main :: IO ()
main = do
  argv <- getArgs
  let (flags, args, errs) = getOpt Permute options argv
  let header = "Usage: bibtex2pandoc [OPTION..] [FILE]"
  unless (null errs && length args < 2) $ do
    hPutStrLn stderr $ usageInfo (unlines $ errs ++ [header]) options
    exitWith $ ExitFailure 1
  when (Version `elem` flags) $ do
    putStrLn $ "bibtex2pandoc " ++ "0.0" -- TODO: showVersion version
    exitWith ExitSuccess
  when (Help `elem` flags) $ do
    putStrLn $ usageInfo header options
    exitWith ExitSuccess
  let isBibtex = Bibtex `elem` flags
  env <- getEnvironment
  let lang = case lookup "LANG" env of
                  Just x  -> case splitWhen (\c -> c == '.' || c == '_') x of
                                   (w:z:_) -> Lang w z
                                   [w]     -> Lang w ""
                                   _       -> Lang "en" "US"
                  Nothing -> Lang "en" "US"
  bibstring <- case args of
                    (x:_) -> readFile x
                    []    -> getContents
  let items = case parse (skippingLeadingSpace file) "stdin" bibstring of
                   Left err -> error (show err)
                   Right xs -> resolveCrossRefs isBibtex
                                  $ map lowercaseFieldNames xs
  putStrLn "---\nreferences:"
  B.putStr $ encode
           $ mapMaybe (itemToReference lang isBibtex) items
  putStrLn "..."

data Option =
    Help | Version | Bibtex
  deriving (Ord, Eq, Show)

options :: [OptDescr Option]
options =
  [ Option ['b'] ["bibtex"] (NoArg Bibtex) "parse as BibTeX, not BibLaTeX"
  , Option ['h'] ["help"] (NoArg Help) "show usage information"
  , Option ['V'] ["version"] (NoArg Version) "show program version"
  ]

lowercaseFieldNames :: T -> T
lowercaseFieldNames e = e{ fields = [(map toLower f, v) | (f,v) <- fields e] }

resolveCrossRefs :: Bool -> [T] -> [T]
resolveCrossRefs isBibtex entries =
  map (resolveCrossRef isBibtex entries) entries

resolveCrossRef :: Bool -> [T] -> T -> T
resolveCrossRef isBibtex entries entry =
  case lookup "crossref" (fields entry) of
       Just xref -> case [e | e <- entries, identifier e == xref] of
                         []     -> entry
                         (e':_)
                          | isBibtex -> entry{ fields = fields entry ++
                                           [(k,v) | (k,v) <- fields e',
                                            isNothing (lookup k $ fields entry)]
                                        }
                          | otherwise -> entry{ fields = fields entry ++
                                          [(k',v) | (k,v) <- fields e',
                                            k' <- transformKey (entryType e')
                                                   (entryType entry) k,
                                           isNothing (lookup k' (fields entry))]
                                              }
       Nothing   -> entry

-- transformKey source target key
-- derived from Appendix C of bibtex manual
transformKey :: String -> String -> String -> [String]
transformKey _ _ "crossref"       = []
transformKey _ _ "xref"           = []
transformKey _ _ "entryset"       = []
transformKey _ _ "entrysubtype"   = []
transformKey _ _ "execute"        = []
transformKey _ _ "label"          = []
transformKey _ _ "options"        = []
transformKey _ _ "presort"        = []
transformKey _ _ "related"        = []
transformKey _ _ "relatedstring"  = []
transformKey _ _ "relatedtype"    = []
transformKey _ _ "shorthand"      = []
transformKey _ _ "shorthandintro" = []
transformKey _ _ "sortkey"        = []
transformKey x y "author"
  | x `elem` ["mvbook", "book"] &&
    y `elem` ["inbook", "bookinbook", "suppbook"] = ["bookauthor"]
transformKey "mvbook" y z
  | y `elem` ["book", "inbook", "bookinbook", "suppbook"] = standardTrans z
transformKey x y z
  | x `elem` ["mvcollection", "mvreference"] &&
    y `elem` ["collection", "reference", "incollection", "suppbook"] =
    standardTrans z
transformKey "mvproceedings" y z
  | y `elem` ["proceedings", "inproceedings"] = standardTrans z
transformKey "book" y z
  | y `elem` ["inbook", "bookinbook", "suppbook"] = standardTrans z
transformKey x y z
  | x `elem` ["collection", "reference"] &&
    y `elem` ["incollection", "inreference", "suppcollection"] = standardTrans z
transformKey "proceedings" "inproceedings" z = standardTrans z
transformKey "periodical" y z
  | y `elem` ["article", "suppperiodical"] =
  case z of
       "title"          -> ["journaltitle"]
       "subtitle"       -> ["journalsubtitle"]
       "shorttitle"     -> []
       "sorttitle"      -> []
       "indextitle"     -> []
       "indexsorttitle" -> []
transformKey _ _ x                = [x]

standardTrans :: String -> [String]
standardTrans z =
  case z of
       "title"          -> ["maintitle"]
       "subtitle"       -> ["mainsubtitle"]
       "titleaddon"     -> ["maintitleaddon"]
       "shorttitle"     -> []
       "sorttitle"      -> []
       "indextitle"     -> []
       "indexsorttitle" -> []
       _                -> [z]

trim :: String -> String
trim = unwords . words

data Lang = Lang String String  -- e.g. "en" "US"

resolveKey :: Lang -> String -> String
resolveKey (Lang "en" "US") k =
  case k of
       "inpreparation" -> "in preparation"
       "submitted"     -> "submitted"
       "forthcoming"   -> "forthcoming"
       "inpress"       -> "in press"
       "prepublished"  -> "pre-published"
       "mathesis"      -> "Master’s thesis"
       "phdthesis"     -> "PhD thesis"
       "candthesis"    -> "Candidate thesis"
       "techreport"    -> "technical report"
       "resreport"     -> "research report"
       "software"      -> "computer software"
       "datacd"        -> "data CD"
       "audiocd"       -> "audio CD"
       _               -> k
resolveKey _ k = resolveKey (Lang "en" "US") k

type Bib = ReaderT T Maybe

notFound :: String -> Bib a
notFound f = fail $ f ++ " not found"

getField :: String -> Bib String
getField f = do
  fs <- asks fields
  case lookup f fs >>= latex of
       Just x  -> return x
       Nothing -> fail "not found"

getTitle :: Lang -> String -> Bib String
getTitle lang f = do
  fs <- asks fields
  case lookup f fs >>= latexTitle lang of
       Just x  -> return x
       Nothing -> fail "not found"

getRawField :: String -> Bib String
getRawField f = do
  fs <- asks fields
  case lookup f fs of
       Just x  -> return x
       Nothing -> fail "not found"

getAuthorList :: String -> Bib [Agent]
getAuthorList f = do
  fs <- asks fields
  case lookup f fs >>= latexAuthors of
       Just xs -> return xs
       Nothing -> notFound f

getLiteralList :: String -> Bib [String]
getLiteralList f = do
  fs <- asks fields
  case lookup f fs of
       Just x  -> return $ map trim $ splitOn " \\and " x
       Nothing -> notFound f

splitByAnd :: [Inline] -> [[Inline]]
splitByAnd = splitOn [Space, Str "and", Space]

toAuthorList :: [Block] -> Maybe [Agent]
toAuthorList [Para xs] =
  Just $ map toAuthor $ splitByAnd xs
toAuthorList [Plain xs] = toAuthorList [Para xs]
toAuthorList x = Nothing

toAuthor :: [Inline] -> Agent
toAuthor [Span ("",[],[]) ils] = -- corporate author
    Agent { givenName       = []
          , droppingPart    = ""
          , nonDroppingPart = ""
          , familyName      = ""
          , nameSuffix      = ""
          , literal         = maybe "" id $ inlinesToString ils
          , commaSuffix     = False
          }
toAuthor ils =
    Agent { givenName       = givens
          , droppingPart    = dropping
          , nonDroppingPart = nondropping
          , familyName      = family
          , nameSuffix      = suffix
          , literal         = ""
          , commaSuffix     = isCommaSuffix
          }
  where inlinesToString' = maybe "" id . inlinesToString
        isCommaSuffix = False -- TODO
        suffix = "" -- TODO
        dropping = "" -- TODO
        endsWithComma (Str zs) = not (null zs) && last zs == ','
        endsWithComma _ = False
        stripComma xs = case reverse xs of
                             (',':ys) -> reverse ys
                             _ -> xs
        (xs, ys) = break endsWithComma ils
        (family, givens, nondropping) =
           case splitOn [Space] ys of
              ((Str w:ws) : rest) ->
                  ( inlinesToString' [Str (stripComma w)]
                  , map inlinesToString' $ if null ws then rest else (ws : rest)
                  , inlinesToString' xs
                  )
              _ -> case reverse xs of
                        []     -> ("", [], "")
                        (z:zs) -> let (us,vs) = break startsWithCapital zs
                                  in  ( inlinesToString' [z]
                                      , map inlinesToString' $ splitOn [Space] $ reverse vs
                                      , inlinesToString' $ dropWhile (==Space) $ reverse us
                                      )

startsWithCapital :: Inline -> Bool
startsWithCapital (Str (x:_)) = isUpper x
startsWithCapital _           = False

latex :: String -> Maybe String
latex s = trim `fmap` blocksToString bs
  where Pandoc _ bs = readLaTeX def s

latexTitle :: Lang -> String -> Maybe String
latexTitle lang s = trim `fmap` blocksToString (unTitlecase bs)
  where Pandoc _ bs = readLaTeX def s

latexAuthors :: String -> Maybe [Agent]
latexAuthors s = toAuthorList bs
  where Pandoc _ bs = readLaTeX def s

bib :: Bib Reference -> T -> Maybe Reference
bib m entry = runReaderT m entry

-- TODO the untitlecase should apply in the latex conversion phase
unTitlecase :: [Block] -> [Block]
unTitlecase [Para ils]  = [Para $ untc ils]
unTitlecase [Plain ils] = [Para $ untc ils]
unTitlecase xs          = xs

untc :: [Inline] -> [Inline]
untc [] = []
untc (x:xs) = x : map go xs
  where go (Str ys)     = Str $ map toLower ys
        go z            = z

toLocale :: String -> String
toLocale "english"    = "en-US" -- "en-EN" unavailable in CSL
toLocale "USenglish"  = "en-US"
toLocale "american"   = "en-US"
toLocale "british"    = "en-GB"
toLocale "UKenglish"  = "en-GB"
toLocale "canadian"   = "en-US" -- "en-CA" unavailable in CSL
toLocale "australian" = "en-GB" -- "en-AU" unavailable in CSL
toLocale "newzealand" = "en-GB" -- "en-NZ" unavailable in CSL
toLocale "afrikaans"  = "af-ZA"
toLocale "arabic"     = "ar"
toLocale "basque"     = "eu"
toLocale "bulgarian"  = "bg-BG"
toLocale "catalan"    = "ca-AD"
toLocale "croatian"   = "hr-HR"
toLocale "czech"      = "cs-CZ"
toLocale "danish"     = "da-DK"
toLocale "dutch"      = "nl-NL"
toLocale "estonian"   = "et-EE"
toLocale "finnish"    = "fi-FI"
toLocale "canadien"   = "fr-CA"
toLocale "acadian"    = "fr-CA"
toLocale "french"     = "fr-FR"
toLocale "francais"   = "fr-FR"
toLocale "austrian"   = "de-AT"
toLocale "naustrian"  = "de-AT"
toLocale "german"     = "de-DE"
toLocale "germanb"    = "de-DE"
toLocale "ngerman"    = "de-DE"
toLocale "greek"      = "el-GR"
toLocale "polutonikogreek" = "el-GR"
toLocale "hebrew"     = "he-IL"
toLocale "hungarian"  = "hu-HU"
toLocale "icelandic"  = "is-IS"
toLocale "italian"    = "it-IT"
toLocale "japanese"   = "ja-JP"
toLocale "latvian"    = "lv-LV"
toLocale "lithuanian" = "lt-LT"
toLocale "magyar"     = "hu-HU"
toLocale "mongolian"  = "mn-MN"
toLocale "norsk"      = "nb-NO"
toLocale "nynorsk"    = "nn-NO"
toLocale "farsi"      = "fa-IR"
toLocale "polish"     = "pl-PL"
toLocale "brazil"     = "pt-BR"
toLocale "brazilian"  = "pt-BR"
toLocale "portugues"  = "pt-PT"
toLocale "portuguese" = "pt-PT"
toLocale "romanian"   = "ro-RO"
toLocale "russian"    = "ru-RU"
toLocale "serbian"    = "sr-RS"
toLocale "serbianc"   = "sr-RS"
toLocale "slovak"     = "sk-SK"
toLocale "slovene"    = "sl-SL"
toLocale "spanish"    = "es-ES"
toLocale "swedish"    = "sv-SE"
toLocale "thai"       = "th-TH"
toLocale "turkish"    = "tr-TR"
toLocale "ukrainian"  = "uk-UA"
toLocale "vietnamese" = "vi-VN"
toLocale _            = ""

itemToReference :: Lang -> Bool -> T -> Maybe Reference
itemToReference lang bibtex = bib $ do
  id' <- asks identifier
  et <- map toLower `fmap` asks entryType
  st <- getRawField "entrysubtype" <|> return ""
  let (reftype, refgenre) = case et of
       "article"
         | st == "magazine"  -> (ArticleMagazine,"")
         | st == "newspaper" -> (ArticleNewspaper,"")
         | otherwise         -> (ArticleJournal,"")
       "book"            -> (Book,"")
       "booklet"         -> (Pamphlet,"")
       "bookinbook"      -> (Book,"")
       "collection"      -> (Book,"")
       "electronic"      -> (Webpage,"")
       "inbook"          -> (Chapter,"")
       "incollection"    -> (Chapter,"")
       "inreference "    -> (Chapter,"")
       "inproceedings"   -> (PaperConference,"")
       "manual"          -> (Book,"")
       "mastersthesis"   -> (Thesis, resolveKey lang "mathesis")
       "misc"            -> (NoType,"")
       "mvbook"          -> (Book,"")
       "mvcollection"    -> (Book,"")
       "mvproceedings"   -> (Book,"")
       "mvreference"     -> (Book,"")
       "online"          -> (Webpage,"")
       "patent"          -> (Patent,"")
       "periodical"
         | st == "magazine"  -> (ArticleMagazine,"")
         | st == "newspaper" -> (ArticleNewspaper,"")
         | otherwise         -> (ArticleJournal,"")
       "phdthesis"       -> (Thesis, resolveKey lang "phdthesis")
       "proceedings"     -> (Book,"")
       "reference"       -> (Book,"")
       "report"          -> (Report,"")
       "suppbook"        -> (Chapter,"")
       "suppcollection"  -> (Chapter,"")
       "suppperiodical"
         | st == "magazine"  -> (ArticleMagazine,"")
         | st == "newspaper" -> (ArticleNewspaper,"")
         | otherwise         -> (ArticleJournal,"")
       "techreport"      -> (Report,"")
       "thesis"          -> (Thesis,"")
       "unpublished"     -> (Manuscript,"")
       "www"             -> (Webpage,"")
       -- biblatex, "unsupporEd"
       "artwork"         -> (Graphic,"")
       "audio"           -> (Song,"")         -- for audio *recordings*
       "commentary"      -> (Book,"")
       "image"           -> (Graphic,"")      -- or "figure" ?
       "jurisdiction"    -> (LegalCase,"")
       "legislation"     -> (Legislation,"")  -- or "bill" ?
       "legal"           -> (Treaty,"")
       "letter"          -> (PersonalCommunication,"")
       "movie"           -> (MotionPicture,"")
       "music"           -> (Song,"")         -- for musical *recordings*
       "performance"     -> (Speech,"")
       "review"          -> (Review,"")       -- or "review-book" ?
       "software"        -> (Book,"")         -- for lack of any better match
       "standard"        -> (Legislation,"")
       "video"           -> (MotionPicture,"")
       -- biblatex-apa:
       "data"            -> (Dataset,"")
       "letters"         -> (PersonalCommunication,"")
       "newsarticle"     -> (ArticleNewspaper,"")
       _                 -> (NoType,"")
  -- hyphenation:
  hyphenation <- toLocale <$> (getRawField "hyphenation" <|> return "english")

  -- authors:
  author' <- getAuthorList "author" <|> return []
  containerAuthor' <- getAuthorList "bookauthor" <|> return []
  translator' <- getAuthorList "translator" <|> return []
  editortype <- getRawField "editortype" <|> return ""
  editor'' <- getAuthorList "editor" <|> return []
  director'' <- getAuthorList "director" <|> return []
  let (editor', director') = case editortype of
                                  "director"  -> ([], editor'')
                                  _           -> (editor'', director'')
  -- FIXME: add same for editora, editorb, editorc

  -- titles
  let processTitle = case hyphenation of
                          'e':'n':_ -> unTitlecase
                          _         -> id
  title' <- getTitle lang "title" <|> return ""
  subtitle' <- (": " ++) `fmap` getTitle lang "subtitle" <|> return ""
  titleaddon' <- (". " ++) `fmap` getTitle lang "titleaddon" <|> return ""
  let hasVolumes = et `elem` ["inbook","incollection","inproceedings","bookinbook"]
  containerTitle' <- getTitle lang "maintitle" <|> getTitle lang "booktitle" <|> return ""
  containerSubtitle' <- (": " ++) `fmap` getTitle lang "mainsubtitle"
                       <|> getTitle lang "booksubtitle" <|> return ""
  containerTitleAddon' <- (". " ++) `fmap` getTitle lang "maintitleaddon"
                       <|> getTitle lang "booktitleaddon" <|> return ""
  volumeTitle' <- (getTitle lang "maintitle" >> guard hasVolumes >> getTitle lang "booktitle")
                       <|> return ""
  volumeSubtitle' <- (": " ++) `fmap`
                       (getTitle lang "maintitle" >> guard hasVolumes >> getTitle lang "booksubtitle")
                       <|> return ""
  volumeTitleAddon' <- (". " ++) `fmap`
                       (getTitle lang "maintitle" >> guard hasVolumes >> getTitle lang "booktitleaddon")
                       <|> return ""
  shortTitle' <- getTitle lang "shorttitle" <|> return ""

  eventTitle' <- getTitle lang "eventtitle" <|> return ""
  origTitle' <- getTitle lang "origtitle" <|> return ""

  -- places
  venue' <- getField "venue" <|> return ""
  address' <- getField "address" <|> return ""

  -- locators
  pages' <- getField "pages" <|> return ""
  volume' <- getField "volume" <|> return ""
  volumes' <- getField "volumes" <|> return ""
  pagetotal' <- getField "pagetotal" <|> return ""

  -- url, doi, isbn, etc.:
  url' <- getRawField "url" <|> return ""
  doi' <- getRawField "doi" <|> return ""
  isbn' <- getRawField "isbn" <|> return ""
  issn' <- getRawField "issn" <|> return ""

  return $ emptyReference
         { refId               = id'
         , refType             = reftype
         , author              = author'
         , editor              = editor'
         , translator          = translator'
         -- , recipient           = undefined -- :: [Agent]
         -- , interviewer         = undefined -- :: [Agent]
         -- , composer            = undefined -- :: [Agent]
         , director            = director'
         -- , illustrator         = undefined -- :: [Agent]
         -- , originalAuthor      = undefined -- :: [Agent]
         , containerAuthor     = containerAuthor'
         -- , collectionEditor    = undefined -- :: [Agent]
         -- , editorialDirector   = undefined -- :: [Agent]
         -- , reviewedAuthor      = undefined -- :: [Agent]

         -- , issued              = undefined -- :: [RefDate]
         -- , eventDate           = undefined -- :: [RefDate]
         -- , accessed            = undefined -- :: [RefDate]
         -- , container           = undefined -- :: [RefDate]
         -- , originalDate        = undefined -- :: [RefDate]
         -- , submitted           = undefined -- :: [RefDate]

         , title               = title' ++ subtitle' ++ titleaddon'
         , titleShort          = shortTitle'
         -- , reviewedTitle       = undefined -- :: String
         , containerTitle      = containerTitle' ++ containerSubtitle' ++ containerTitleAddon'
         , collectionTitle     = volumeTitle' ++ volumeSubtitle' ++ volumeTitleAddon'
         -- , containerTitleShort = undefined -- :: String
         -- , collectionNumber    = undefined -- :: String --Int
         , originalTitle       = origTitle'
         -- , publisher           = undefined -- :: String
         -- , originalPublisher   = undefined -- :: String
         , publisherPlace      = address'
         -- , originalPublisherPlace = undefined -- :: String
         -- , authority           = undefined -- :: String
         -- , jurisdiction        = undefined -- :: String
         -- , archive             = undefined -- :: String
         -- , archivePlace        = undefined -- :: String
         -- , archiveLocation     = undefined -- :: String
         , event               = eventTitle'
         , eventPlace          = venue'
         , page                = pages'
         -- , pageFirst           = undefined -- :: String
         , numberOfPages       = pagetotal'
         -- , version             = undefined -- :: String
         , volume              = volume'
         , numberOfVolumes     = volumes'
         -- , issue               = undefined -- :: String
         -- , chapterNumber       = undefined -- :: String
         -- , medium              = undefined -- :: String
         -- , status              = undefined -- :: String
         -- , edition             = undefined -- :: String
         -- , section             = undefined -- :: String
         -- , source              = undefined -- :: String
         , genre               = refgenre
         -- , note                = undefined -- :: String
         -- , annote              = undefined -- :: String
         -- , abstract            = undefined -- :: String
         -- , keyword             = undefined -- :: String
         -- , number              = undefined -- :: String
         -- , references          = undefined -- :: String
         , url                 = url'
         , doi                 = doi'
         , isbn                = isbn'
         , issn                = issn'
         -- , pmcid               = undefined -- :: String
         -- , pmid                = undefined -- :: String
         -- , callNumber          = undefined -- :: String
         -- , dimensions          = undefined -- :: String
         -- , scale               = undefined -- :: String
         -- , categories          = undefined -- :: [String]
         -- , language            = undefined -- :: String

         -- , citationNumber      = undefined --      :: CNum
         -- , firstReferenceNoteNumber = undefined -- :: Int
         -- , citationLabel       = undefined --      :: String
         --  MISSING: hyphenation :: String
         }
{-
-- dates:
  opt $ getField' "year" >>= setSubField "issued" "year"
  opt $ getField' "month" >>= setSubField "issued" "month"
--  opt $ getField' "date" >>= setField "issued" -- FIXME
  opt $ do
    dateraw <- getRawField' "date"
    let datelist = T.splitOn (T.pack "-") (T.pack dateraw)
    let year = T.unpack (datelist !! 0)
    if length (datelist) > 1
    then do
      let month = T.unpack (datelist !! 1)
      setSubField "issued" "month" (MetaString month)
      if length (datelist) > 2
      then do
        let day = T.unpack (datelist !! 2)
        setSubField "issued" "day" (MetaString day)
      else return ()
    else return ()
    setSubField "issued" "year" (MetaString year)
--  opt $ getField' "urldate" >>= setField "accessed" -- FIXME
  opt $ do
    dateraw <- getRawField' "urldate"
    let datelist = T.splitOn (T.pack "-") (T.pack dateraw)
    let year = T.unpack (datelist !! 0)
    if length (datelist) > 1
    then do
      let month = T.unpack (datelist !! 1)
      setSubField "accessed" "month" (MetaString month)
      if length (datelist) > 2
      then do
        let day = T.unpack (datelist !! 2)
        setSubField "accessed" "day" (MetaString day)
      else return ()
    else return ()
    setSubField "accessed" "year" (MetaString year)
  opt $ getField' "eventdate" >>= setField "event-date"   -- FIXME
  opt $ getField' "origdate" >>= setField "original-date" -- FIXME
-- titles:
  -- handling of "periodical" to be revised as soon as new "issue-title" variable
  --   is included into CSL specs
  -- A biblatex "note" field in @periodical usually contains sth. like "Special issue"
  -- At least for CMoS, APA, borrowing "genre" for this works reasonably well.
  opt $ do
    if  et == "periodical" then do
      opt $ getField' "title" >>= setField "container-title"
      opt $ getField' "issuetitle" >>= setField "title" . processTitle
      opt $ getField' "issuesubtitle" >>= appendField "title" addColon . processTitle
      opt $ getField' "note" >>= appendField "genre" addPeriod . processTitle
    else return ()
  opt $ getField' "journal" >>= setField "container-title"
  opt $ getField' "journaltitle" >>= setField "container-title"
  opt $ getField' "journalsubtitle" >>= appendField "container-title" addColon
  opt $ getField' "shortjournal" >>= setField "container-title-short"
  opt $ getField' "series" >>= appendField (if et `elem` ["article","periodical","suppperiodical"]
                                        then "container-title"
                                        else "collection-title") addComma
-- publisher, location:
--   opt $ getField' "school" >>= setField "publisher"
--   opt $ getField' "institution" >>= setField "publisher"
--   opt $ getField' "organization" >>= setField "publisher"
--   opt $ getField' "howpublished" >>= setField "publisher"
--   opt $ getField' "publisher" >>= setField "publisher"

  opt $ getField' "school" >>= appendField "publisher" addComma
  opt $ getField' "institution" >>= appendField "publisher" addComma
  opt $ getField' "organization" >>= appendField "publisher" addComma
  opt $ getField' "howpublished" >>= appendField "publisher" addComma
  opt $ getField' "publisher" >>= appendField "publisher" addComma

  unless bibtex $ do
    opt $ getField' "location" >>= setField "publisher-place"
  opt $ getLiteralList' "origlocation" >>=
             setList "original-publisher-place"
  opt $ getLiteralList' "origpublisher" >>= setList "original-publisher"
-- numbers, locators etc.:
  opt $ getField' "number" >>=
             setField (if et `elem` ["article","periodical","suppperiodical"]
                       then "issue"
                       else if et `elem` ["book","collection","proceedings","reference",
                       "mvbook","mvcollection","mvproceedings","mvreference",
                       "bookinbook","inbook","incollection","inproceedings","inreference",
                       "suppbook","suppcollection"]
                       then "collection-number"
                       else "number")                     -- "report", "patent", etc.
  opt $ getField' "issue" >>= appendField "issue" addComma
  opt $ getField' "chapter" >>= setField "chapter-number"
  opt $ getField' "edition" >>= setField "edition"
  opt $ getField' "version" >>= setField "version"
  opt $ getRawField' "type" >>= setRawField "genre" . resolveKey lang
  opt $ getRawField' "pubstate" >>= setRawField "status" . resolveKey lang
-- note etc.
  unless (et == "periodical") $ do
    opt $ getField' "note" >>= setField "note"
  unless bibtex $ do
    opt $ getField' "addendum" >>= appendField "note" (Space:)
  opt $ getField' "annotation" >>= setField "annote"
  opt $ getField' "annote" >>= setField "annote"
  opt $ getField' "abstract" >>= setField "abstract"
  opt $ getField' "keywords" >>= setField "keyword"

addColon :: [Inline] -> [Inline]
addColon xs = [Str ":",Space] ++ xs

addComma :: [Inline] -> [Inline]
addComma xs = [Str ",",Space] ++ xs

addPeriod :: [Inline] -> [Inline]
addPeriod xs = [Str ".",Space] ++ xs

inParens :: [Inline] -> [Inline]
inParens xs = [Space, Str "("] ++ xs ++ [Str ")"]

toLiteralList :: MetaValue -> [MetaValue]
toLiteralList (MetaBlocks [Para xs]) =
  map MetaInlines $ splitByAnd xs
toLiteralList (MetaBlocks []) = []
toLiteralList x = error $ "toLiteralList: " ++ show x

latex' :: String -> MetaValue
latex' s = MetaBlocks bs
  where Pandoc _ bs = readLaTeX def s


type BibM = RWST T () (M.Map String MetaValue) Maybe

opt :: BibM () -> BibM ()
opt m = m `mplus` return ()

getField' :: String -> BibM MetaValue
getField' f = do
  fs <- asks fields
  case lookup f fs of
       Just x  -> return $ latex' x
       Nothing -> fail "not found"

setField :: String -> MetaValue -> BibM ()
setField f x = modify $ M.insert f x

appendField :: String -> ([Inline] -> [Inline]) -> MetaValue -> BibM ()
appendField f fn x = modify $ M.insertWith combine f x
  where combine new old = MetaInlines $ toInlines old ++ fn (toInlines new)
        toInlines (MetaInlines ils) = ils
        toInlines (MetaBlocks [Para ils]) = ils
        toInlines (MetaBlocks [Plain ils]) = ils
        toInlines _ = []

notFound :: String -> BibM a
notFound f = fail $ f ++ " not found"

getId :: BibM String
getId = asks identifier

getRawField' :: String -> BibM String
getRawField' f = do
  fs <- asks fields
  case lookup f fs of
       Just x  -> return x
       Nothing -> notFound f

setRawField :: String -> String -> BibM ()
setRawField f x = modify $ M.insert f (MetaString x)

getAuthorList' :: String -> BibM [MetaValue]
getAuthorList' f = do
  fs <- asks fields
  case lookup f fs of
       Just x  -> return $ toAuthorList' $ latex' x
       Nothing -> notFound f

getLiteralList' :: String -> BibM [MetaValue]
getLiteralList' f = do
  fs <- asks fields
  case lookup f fs of
       Just x  -> return $ toLiteralList $ latex' x
       Nothing -> notFound f

setList :: String -> [MetaValue] -> BibM ()
setList f xs = modify $ M.insert f $ MetaList xs

setSubField :: String -> String -> MetaValue -> BibM ()
setSubField f k v = do
  fs <- get
  case M.lookup f fs of
       Just (MetaMap m) -> modify $ M.insert f (MetaMap $ M.insert k v m)
       _ -> modify $ M.insert f (MetaMap $ M.singleton k v)

bibItem :: BibM a -> T -> MetaValue
bibItem m entry = MetaMap $ maybe M.empty fst $ execRWST m entry M.empty

getEntryType :: BibM String
getEntryType = asks entryType

isPresent :: String -> BibM Bool
isPresent f = do
  fs <- asks fields
  case lookup f fs of
       Just _   -> return True
       Nothing  -> return False

-}