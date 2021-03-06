{-# LANGUAGE DeriveDataTypeable, RankNTypes #-}
-- |
-- Copyright: 2011 Michael Snoyman, 2010-2011 John Millikin
-- License: MIT
--
-- Handle streams of text.
--
-- Parts of this code were taken from enumerator and adapted for conduits.
module Data.Conduit.Text
    (

    -- * Text codecs
      Codec
    , encode
    , decode
    , utf8
    , utf16_le
    , utf16_be
    , utf32_le
    , utf32_be
    , ascii
    , iso8859_1
    , lines
    , linesBounded
    , TextException (..)
    , takeWhile
    , dropWhile
    , take
    , drop
    , foldLines
    , withLine
    , decodeUtf8
    , encodeUtf8
    ) where

import qualified Prelude
import           Prelude hiding (head, drop, takeWhile, lines, zip, zip3, zipWith, zipWith3, take, dropWhile)

import qualified Control.Exception as Exc
import qualified Data.ByteString as B
import qualified Data.ByteString.Char8 as B8
import           Data.Char (ord)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import           Data.Word (Word8)
import           Data.Typeable (Typeable)

import Data.Conduit
import qualified Data.Conduit.List as CL
import Control.Monad.Trans.Class (lift)
import Control.Monad (unless,when)
import Data.Text.StreamDecoding

-- | A specific character encoding.
--
-- Since 0.3.0
data Codec = Codec
    { codecName :: T.Text
    , codecEncode
        :: T.Text
        -> (B.ByteString, Maybe (TextException, T.Text))
    , codecDecode
        :: B.ByteString
        -> (T.Text, Either
            (TextException, B.ByteString)
            B.ByteString)
    }
    | NewCodec T.Text (T.Text -> B.ByteString) (B.ByteString -> DecodeResult)

instance Show Codec where
    showsPrec d c = showParen (d > 10) $
        showString "Codec " . shows (codecName c)




-- | Emit each line separately
--
-- Since 0.4.1
lines :: Monad m => Conduit T.Text m T.Text
lines =
    loop id
  where
    loop front = await >>= maybe (finish front) (go front)

    finish front =
        let final = front T.empty
         in unless (T.null final) (yield final)

    go sofar more =
        case T.uncons second of
            Just (_, second') -> yield (sofar first') >> go id second'
            Nothing ->
                let rest = sofar more
                 in loop $ T.append rest
      where
        (first', second) = T.break (== '\n') more



-- | Variant of the lines function with an integer parameter.
-- The text length of any emitted line
-- never exceeds the value of the paramater. Whenever
-- this is about to happen a LengthExceeded exception
-- is thrown. This function should be used instead
-- of the lines function whenever we are dealing with
-- user input (e.g. a file upload) because we can't be sure that
-- user input won't have extraordinarily large lines which would
-- require large amounts of memory if consumed.
linesBounded :: MonadThrow m => Int -> Conduit T.Text m T.Text
linesBounded maxLineLen =
    loop 0 id
  where
    loop len front = await >>= maybe (finish front) (go len front)

    finish front =
        let final = front T.empty
         in unless (T.null final) (yield final)
    go len sofar more =
        case T.uncons second of
            Just (_, second') -> do
                let toYield = sofar first'
                    len' = len + T.length first'
                when (len' > maxLineLen)
                    (lift $ monadThrow (LengthExceeded maxLineLen))
                yield toYield
                go 0 id second'
            Nothing -> do
                let len' = len + T.length more
                when (len' > maxLineLen) $
                    (lift $ monadThrow (LengthExceeded maxLineLen))
                let rest = sofar more
                loop len' $ T.append rest
      where
        (first', second) = T.break (== '\n') more



-- | Convert text into bytes, using the provided codec. If the codec is
-- not capable of representing an input character, an exception will be thrown.
--
-- Since 0.3.0
encode :: MonadThrow m => Codec -> Conduit T.Text m B.ByteString
encode (NewCodec _ enc _) = CL.map enc
encode codec = CL.mapM $ \t -> do
    let (bs, mexc) = codecEncode codec t
    maybe (return bs) (monadThrow . fst) mexc


-- | Convert bytes into text, using the provided codec. If the codec is
-- not capable of decoding an input byte sequence, an exception will be thrown.
--
-- Since 0.3.0
decode :: MonadThrow m => Codec -> Conduit B.ByteString m T.Text
decode (NewCodec name _ start) =
    loop 0 start
  where
    loop consumed dec =
        await >>= maybe finish go
      where
        finish =
            case dec B.empty of
                DecodeResultSuccess _ _ -> return ()
                DecodeResultFailure t rest -> onFailure B.empty t rest
        {-# INLINE finish #-}

        go bs | B.null bs = loop consumed dec
        go bs =
            case dec bs of
                DecodeResultSuccess t dec' -> do
                    let consumed' = consumed + B.length bs
                        next = do
                            unless (T.null t) (yield t)
                            loop consumed' dec'
                     in consumed' `seq` next
                DecodeResultFailure t rest -> onFailure bs t rest

        onFailure bs t rest = do
            unless (T.null t) (yield t)
            leftover rest -- rest will never be null, no need to check
            let consumed' = consumed + B.length bs - B.length rest
            monadThrow $ NewDecodeException name consumed' (B.take 4 rest)
        {-# INLINE onFailure #-}
decode codec =
    loop id
  where
    loop front = await >>= maybe (finish front) (go front)

    finish front =
        case B.uncons $ front B.empty of
            Nothing -> return ()
            Just (w, _) -> lift $ monadThrow $ DecodeException codec w

    go front bs' =
        case extra of
            Left (exc, _) -> lift $ monadThrow exc
            Right bs'' -> yield text >> loop (B.append bs'')
      where
        (text, extra) = codecDecode codec bs
        bs = front bs'

-- |
-- Since 0.3.0
data TextException = DecodeException Codec Word8
                   | EncodeException Codec Char
                   | LengthExceeded Int
                   | TextException Exc.SomeException
                   | NewDecodeException !T.Text !Int !B.ByteString
    deriving Typeable
instance Show TextException where
    show (DecodeException codec w) = concat
        [ "Error decoding legacy Data.Conduit.Text codec "
        , show codec
        , " when parsing byte: "
        , show w
        ]
    show (EncodeException codec c) = concat
        [ "Error encoding legacy Data.Conduit.Text codec "
        , show codec
        , " when parsing char: "
        , show c
        ]
    show (LengthExceeded i) = "Data.Conduit.Text.linesBounded: line too long: " ++ show i
    show (TextException se) = "Data.Conduit.Text.TextException: " ++ show se
    show (NewDecodeException codec consumed next) = concat
        [ "Data.Conduit.Text.decode: Error decoding stream of "
        , T.unpack codec
        , " bytes. Error encountered in stream at offset "
        , show consumed
        , ". Encountered at byte sequence "
        , show next
        ]
instance Exc.Exception TextException

-- |
-- Since 0.3.0
utf8 :: Codec
utf8 = NewCodec (T.pack "UTF-8") TE.encodeUtf8 streamUtf8

-- |
-- Since 0.3.0
utf16_le :: Codec
utf16_le = NewCodec (T.pack "UTF-16-LE") TE.encodeUtf16LE streamUtf16LE

-- |
-- Since 0.3.0
utf16_be :: Codec
utf16_be = NewCodec (T.pack "UTF-16-BE") TE.encodeUtf16BE streamUtf16BE

-- |
-- Since 0.3.0
utf32_le :: Codec
utf32_le = NewCodec (T.pack "UTF-32-LE") TE.encodeUtf32LE streamUtf32LE

-- |
-- Since 0.3.0
utf32_be :: Codec
utf32_be = NewCodec (T.pack "UTF-32-BE") TE.encodeUtf32BE streamUtf32BE

-- |
-- Since 0.3.0
ascii :: Codec
ascii = Codec name enc dec where
    name = T.pack "ASCII"
    enc text = (bytes, extra) where
        (safe, unsafe) = T.span (\c -> ord c <= 0x7F) text
        bytes = B8.pack (T.unpack safe)
        extra = if T.null unsafe
            then Nothing
            else Just (EncodeException ascii (T.head unsafe), unsafe)

    dec bytes = (text, extra) where
        (safe, unsafe) = B.span (<= 0x7F) bytes
        text = T.pack (B8.unpack safe)
        extra = if B.null unsafe
            then Right B.empty
            else Left (DecodeException ascii (B.head unsafe), unsafe)

-- |
-- Since 0.3.0
iso8859_1 :: Codec
iso8859_1 = Codec name enc dec where
    name = T.pack "ISO-8859-1"
    enc text = (bytes, extra) where
        (safe, unsafe) = T.span (\c -> ord c <= 0xFF) text
        bytes = B8.pack (T.unpack safe)
        extra = if T.null unsafe
            then Nothing
            else Just (EncodeException iso8859_1 (T.head unsafe), unsafe)

    dec bytes = (T.pack (B8.unpack bytes), Right B.empty)

-- |
--
-- Since 1.0.8
takeWhile :: Monad m
          => (Char -> Bool)
          -> Conduit T.Text m T.Text
takeWhile p =
    loop
  where
    loop = await >>= maybe (return ()) go
    go t =
        case T.span p t of
            (x, y)
                | T.null y -> yield x >> loop
                | otherwise -> yield x >> leftover y

-- |
--
-- Since 1.0.8
dropWhile :: Monad m
          => (Char -> Bool)
          -> Consumer T.Text m ()
dropWhile p =
    loop
  where
    loop = await >>= maybe (return ()) go
    go t
        | T.null x = loop
        | otherwise = leftover x
      where
        x = T.dropWhile p t

-- |
--
-- Since 1.0.8
take :: Monad m => Int -> Conduit T.Text m T.Text
take =
    loop
  where
    loop i = await >>= maybe (return ()) (go i)
    go i t
        | diff == 0 = yield t
        | diff < 0 =
            let (x, y) = T.splitAt i t
             in yield x >> leftover y
        | otherwise = yield t >> loop diff
      where
        diff = i - T.length t

-- |
--
-- Since 1.0.8
drop :: Monad m => Int -> Consumer T.Text m ()
drop =
    loop
  where
    loop i = await >>= maybe (return ()) (go i)
    go i t
        | diff == 0 = return ()
        | diff < 0 = leftover $ T.drop i t
        | otherwise = loop diff
      where
        diff = i - T.length t

-- |
--
-- Since 1.0.8
foldLines :: Monad m
          => (a -> ConduitM T.Text o m a)
          -> a
          -> ConduitM T.Text o m a
foldLines f =
    start
  where
    start a = CL.peek >>= maybe (return a) (const $ loop $ f a)

    loop consumer = do
        a <- takeWhile (/= '\n') =$= do
            a <- CL.map (T.filter (/= '\r')) =$= consumer
            CL.sinkNull
            return a
        drop 1
        start a

-- |
--
-- Since 1.0.8
withLine :: Monad m
         => Sink T.Text m a
         -> Consumer T.Text m (Maybe a)
withLine consumer = toConsumer $ do
    mx <- CL.peek
    case mx of
        Nothing -> return Nothing
        Just _ -> do
            x <- takeWhile (/= '\n') =$ do
                x <- CL.map (T.filter (/= '\r')) =$ consumer
                CL.sinkNull
                return x
            drop 1
            return $ Just x

-- | Decode a stream of UTF8-encoded bytes into a stream of text, throwing an
-- exception on invalid input.
--
-- Since 1.0.15
decodeUtf8 :: MonadThrow m => Conduit B.ByteString m T.Text
decodeUtf8 = decode utf8
    {- no meaningful performance advantage
    CI.ConduitM (loop 0 streamUtf8)
  where
    loop consumed dec =
        CI.NeedInput go finish
      where
        finish () =
            case dec B.empty of
                DecodeResultSuccess _ _ -> return ()
                DecodeResultFailure t rest -> onFailure B.empty t rest
        {-# INLINE finish #-}

        go bs | B.null bs = CI.NeedInput go finish
        go bs =
            case dec bs of
                DecodeResultSuccess t dec' -> do
                    let consumed' = consumed + B.length bs
                        next' = loop consumed' dec'
                        next
                            | T.null t = next'
                            | otherwise = CI.HaveOutput next' (return ()) t
                     in consumed' `seq` next
                DecodeResultFailure t rest -> onFailure bs t rest

        onFailure bs t rest = do
            unless (T.null t) (CI.yield t)
            unless (B.null rest) (CI.leftover rest)
            let consumed' = consumed + B.length bs - B.length rest
            monadThrow $ NewDecodeException (T.pack "UTF-8") consumed' (B.take 4 rest)
        {-# INLINE onFailure #-}
    -}
{-# INLINE decodeUtf8 #-}

-- | Encode a stream of text into a stream of bytes.
--
-- Since 1.0.15
encodeUtf8 :: Monad m => Conduit T.Text m B.ByteString
encodeUtf8 = CL.map TE.encodeUtf8
{-# INLINE encodeUtf8 #-}
