{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE CPP #-}

module Net.Internal where

import Data.Monoid ((<>))
import Data.Word
import Data.Bits ((.&.),(.|.),shiftR,shiftL,shift,complement,unsafeShiftR,unsafeShiftL)
import Control.Monad.ST
import Data.Text.Internal (Text(..))
import Data.ByteString (ByteString)
import Data.Text.Lazy.Builder.Int (decimal)
import Control.Monad
import Text.Printf (printf)
import Data.Char (chr,ord)
import Data.Word.Synthetic (Word48)
import qualified Data.Text              as Text
import qualified Data.Text.Lazy         as LText
import qualified Data.Attoparsec.Text   as AT
import qualified Data.Aeson.Types       as Aeson
import qualified Data.Text.Array        as TArray
import qualified Data.ByteString.Char8  as BC8
import qualified Data.ByteString        as ByteString
import qualified Data.ByteString.Unsafe as ByteString
import qualified Data.Text.Lazy.Builder as TBuilder
import qualified Data.Text.Read         as TextRead
import qualified Data.Text.Lazy.Builder.Int as TBuilder

-- | Taken from @Data.ByteString.Internal@. The same warnings
--   apply here.
c2w :: Char -> Word8
c2w = fromIntegral . ord
{-# INLINE c2w #-}

eitherToAesonParser :: Either String a -> Aeson.Parser a
eitherToAesonParser x = case x of
  Left err -> fail err
  Right a -> return a

attoparsecParseJSON :: AT.Parser a -> Aeson.Value -> Aeson.Parser a
attoparsecParseJSON p v =
  case v of
    Aeson.String t ->
      case AT.parseOnly p t of
        Left err  -> fail err
        Right res -> return res
    _ -> fail "expected a String"

stripDecimal :: Text -> Either String Text
stripDecimal t = case Text.uncons t of
  Nothing -> Left "expected a dot but input ended instead"
  Just (c,tnext) -> if c == '.'
    then Right tnext
    else Left "expected a dot but found a different character"
{-# INLINE stripDecimal #-}

decodeIPv4TextReader :: TextRead.Reader Word32
decodeIPv4TextReader t1' = do
  (a,t2) <- TextRead.decimal t1'
  t2' <- stripDecimal t2
  (b,t3) <- TextRead.decimal t2'
  t3' <- stripDecimal t3
  (c,t4) <- TextRead.decimal t3'
  t4' <- stripDecimal t4
  (d,t5) <- TextRead.decimal t4'
  if a > 255 || b > 255 || c > 255 || d > 255
    then Left ipOctetSizeErrorMsg
    else Right (fromOctets' a b c d,t5)
{-# INLINE decodeIPv4TextReader #-}

decodeIPv4TextEither :: Text -> Either String Word32
decodeIPv4TextEither t = case decodeIPv4TextReader t of
  Left err -> Left err
  Right (w,t') -> if Text.null t'
    then Right w
    else Left "expected end of text but it continued instead"

ipOctetSizeErrorMsg :: String
ipOctetSizeErrorMsg = "All octets in an IPv4 address must be between 0 and 255"

rightToMaybe :: Either a b -> Maybe b
rightToMaybe = either (const Nothing) Just

toDotDecimalText :: Word32 -> Text
toDotDecimalText = toTextPreAllocated
{-# INLINE toDotDecimalText #-}

toDotDecimalBuilder :: Word32 -> TBuilder.Builder
toDotDecimalBuilder = TBuilder.fromText . toTextPreAllocated
{-# INLINE toDotDecimalBuilder #-}

rangeToDotDecimalText :: Word32 -> Word8 -> Text
rangeToDotDecimalText addr len =
  LText.toStrict (TBuilder.toLazyText (rangeToDotDecimalBuilder addr len))

rangeToDotDecimalBuilder :: Word32 -> Word8 -> TBuilder.Builder
rangeToDotDecimalBuilder addr len =
  toDotDecimalBuilder addr
  <> TBuilder.singleton '/'
  <> decimal len

-- | I think that this function can be improved. Right now, it
--   always allocates enough space for a fifteen-character text
--   rendering of an IP address. I think that it should be possible
--   to do more of the math upfront and allocate less space.
toTextPreAllocated :: Word32 -> Text
toTextPreAllocated w =
  let w1 = 255 .&. unsafeShiftR (fromIntegral w) 24
      w2 = 255 .&. unsafeShiftR (fromIntegral w) 16
      w3 = 255 .&. unsafeShiftR (fromIntegral w) 8
      w4 = 255 .&. fromIntegral w
   in toTextPreallocatedPartTwo w1 w2 w3 w4

toTextPreallocatedPartTwo :: Word -> Word -> Word -> Word -> Text
toTextPreallocatedPartTwo w1 w2 w3 w4 =
#ifdef ghcjs_HOST_OS
  let dotStr = "."
   in Text.pack $ concat
        [ show w1
        , "."
        , show w2
        , "."
        , show w3
        , "."
        , show w4
        ]
#else
  let dot = 46
      (arr,len) = runST $ do
        marr <- TArray.new 15
        i1 <- putAndCount 0 w1 marr
        let n1 = i1
            n1' = i1 + 1
        TArray.unsafeWrite marr n1 dot
        i2 <- putAndCount n1' w2 marr
        let n2 = i2 + n1'
            n2' = n2 + 1
        TArray.unsafeWrite marr n2 dot
        i3 <- putAndCount n2' w3 marr
        let n3 = i3 + n2'
            n3' = n3 + 1
        TArray.unsafeWrite marr n3 dot
        i4 <- putAndCount n3' w4 marr
        theArr <- TArray.unsafeFreeze marr
        return (theArr,i4 + n3')
   in Text arr 0 len
#endif

putAndCount :: Int -> Word -> TArray.MArray s -> ST s Int
putAndCount pos w marr
  | w < 10 = TArray.unsafeWrite marr pos (i2w w) >> return 1
  | w < 100 = write2 pos w >> return 2
  | otherwise = write3 pos w >> return 3
  where
  write2 off i0 = do
    let i = fromIntegral i0; j = i + i
    TArray.unsafeWrite marr off $ get2 j
    TArray.unsafeWrite marr (off + 1) $ get2 (j + 1)
  write3 off i0 = do
    let i = fromIntegral i0; j = i + i + i
    TArray.unsafeWrite marr off $ get3 j
    TArray.unsafeWrite marr (off + 1) $ get3 (j + 1)
    TArray.unsafeWrite marr (off + 2) $ get3 (j + 2)
  get2 = fromIntegral . ByteString.unsafeIndex twoDigits
  get3 = fromIntegral . ByteString.unsafeIndex threeDigitsWord8

putMac :: ByteString -> Int -> Word64 -> TArray.MArray s -> ST s ()
putMac hexPairs pos w' marr = do
  let w = fromIntegral w'
      i = w + w
  TArray.unsafeWrite marr pos $ fromIntegral $ ByteString.unsafeIndex hexPairs i
  TArray.unsafeWrite marr (pos + 1) $ fromIntegral $ ByteString.unsafeIndex hexPairs (i + 1)
{-# INLINE putMac #-}

macToTextDefault :: Word48 -> Text
macToTextDefault = macToTextPreAllocated 58 False

macToTextPreAllocated :: Word8 -> Bool -> Word48 -> Text
macToTextPreAllocated separator' isUpperCase w =
  let w1 = 255 .&. unsafeShiftR (fromIntegral w) 40
      w2 = 255 .&. unsafeShiftR (fromIntegral w) 32
      w3 = 255 .&. unsafeShiftR (fromIntegral w) 24
      w4 = 255 .&. unsafeShiftR (fromIntegral w) 16
      w5 = 255 .&. unsafeShiftR (fromIntegral w) 8
      w6 = 255 .&. fromIntegral w
  in macToTextPartTwo separator' isUpperCase w1 w2 w3 w4 w5 w6
{-# INLINE macToTextPreAllocated #-}

macToTextPartTwo :: Word8 -> Bool -> Word64 -> Word64 -> Word64 -> Word64 -> Word64 -> Word64 -> Text
macToTextPartTwo separator' isUpperCase w1 w2 w3 w4 w5 w6 =
#ifdef ghcjs_HOST_OS
  Text.pack $ concat
    [ toHex w1
    , separatorStr
    , toHex w2
    , separatorStr
    , toHex w3
    , separatorStr
    , toHex w4
    , separatorStr
    , toHex w5
    , separatorStr
    , toHex w6
    ]
  where
  toHex :: Word64 -> String
  toHex = if isUpperCase then printf "%02X" else printf "%02x"
  separatorStr = [chr (fromEnum separator')]
#else
  let hexPairs = if isUpperCase then twoHexDigits else twoHexDigitsLower
      separator = fromIntegral separator' :: Word16
      arr = runST $ do
        marr <- TArray.new 17
        putMac hexPairs 0 w1 marr
        TArray.unsafeWrite marr 2 separator
        putMac hexPairs 3 w2 marr
        TArray.unsafeWrite marr 5 separator
        putMac hexPairs 6 w3 marr
        TArray.unsafeWrite marr 8 separator
        putMac hexPairs 9 w4 marr
        TArray.unsafeWrite marr 11 separator
        putMac hexPairs 12 w5 marr
        TArray.unsafeWrite marr 14 separator
        putMac hexPairs 15 w6 marr
        TArray.unsafeFreeze marr
  in Text arr 0 17
#endif
{-# INLINE macToTextPartTwo #-}


zero :: Word16
zero = 48
{-# INLINE zero #-}

i2w :: Integral a => a -> Word16
i2w v = zero + fromIntegral v
{-# INLINE i2w #-}


fromDotDecimalText' :: Text -> Either String Word32
fromDotDecimalText' t =
  AT.parseOnly (dotDecimalParser <* AT.endOfInput) t

fromDotDecimalText :: Text -> Maybe Word32
fromDotDecimalText = rightToMaybe . fromDotDecimalText'

rangeFromDotDecimalText' :: (Word32 -> Word8 -> a) -> Text -> Either String a
rangeFromDotDecimalText' f t =
  AT.parseOnly (dotDecimalRangeParser f <* AT.endOfInput) t
{-# INLINE rangeFromDotDecimalText' #-}

rangeFromDotDecimalText :: (Word32 -> Word8 -> a) -> Text -> Maybe a
rangeFromDotDecimalText f = rightToMaybe . rangeFromDotDecimalText' f

dotDecimalRangeParser :: (Word32 -> Word8 -> a) -> AT.Parser a
dotDecimalRangeParser f = f
  <$> dotDecimalParser
  <*  AT.char '/'
  <*> (AT.decimal >>= limitSize)
  where
  limitSize i =
    if i > 32
      then fail "An IP range length must be between 0 and 32"
      else return i

-- | This does not do an endOfInput check because it is
-- reused in the range parser implementation.
dotDecimalParser :: AT.Parser Word32
dotDecimalParser = fromOctets'
  <$> (AT.decimal >>= limitSize)
  <*  AT.char '.'
  <*> (AT.decimal >>= limitSize)
  <*  AT.char '.'
  <*> (AT.decimal >>= limitSize)
  <*  AT.char '.'
  <*> (AT.decimal >>= limitSize)
  where
  limitSize i =
    if i > 255
      then fail ipOctetSizeErrorMsg
      else return i

-- | This is sort of a misnomer. It takes Word32 to make
--   dotDecimalParser probably perform better. This is mostly
--   for internal use.
--
--   At some point, it would be worth revisiting the decision
--   to use 'Word32' here. Using 'Word' would probably give
--   better performance on a 64-bit processor.
fromOctets' :: Word32 -> Word32 -> Word32 -> Word32 -> Word32
fromOctets' a b c d =
    ( shiftL a 24
  .|. shiftL b 16
  .|. shiftL c 8
  .|. d
    )

fromOctetsV6 ::
     Word64 -> Word64 -> Word64 -> Word64
  -> Word64 -> Word64 -> Word64 -> Word64
  -> Word64 -> Word64 -> Word64 -> Word64
  -> Word64 -> Word64 -> Word64 -> Word64
  -> (Word64,Word64)
fromOctetsV6 a b c d e f g h i j k l m n o p =
  ( fromOctetsWord64 a b c d e f g h
  , fromOctetsWord64 i j k l m n o p
  )

fromWord16sV6 ::
     Word64 -> Word64 -> Word64 -> Word64
  -> Word64 -> Word64 -> Word64 -> Word64
  -> (Word64,Word64)
fromWord16sV6 a b c d e f g h =
  ( fromWord16Word64 a b c d
  , fromWord16Word64 e f g h
  )

fromWord16Word64 :: Word64 -> Word64 -> Word64 -> Word64 -> Word64
fromWord16Word64 a b c d = fromIntegral
    ( unsafeShiftL a 48
  .|. unsafeShiftL b 32
  .|. unsafeShiftL c 16
  .|. d
    )

-- | All the words given as argument should be
--   range restricted from 0 to 255. This is not
--   checked.
fromOctetsWord64 ::
     Word64 -> Word64 -> Word64 -> Word64
  -> Word64 -> Word64 -> Word64 -> Word64
  -> Word64
fromOctetsWord64 a b c d e f g h = fromIntegral
    ( shiftL a 56
  .|. shiftL b 48
  .|. shiftL c 40
  .|. shiftL d 32
  .|. shiftL e 24
  .|. shiftL f 16
  .|. shiftL g 8
  .|. h
    )

-- | Given the size of the mask, return the
--   total number of ips in the subnet. This
--   only works for IPv4 addresses because
--   an IPv6 subnet can have up to 2^128
--   addresses.
countAddrs :: Word8 -> Word64
countAddrs w =
  let amountToShift = if w > 32
        then 0
        else 32 - fromIntegral w
   in shift 1 amountToShift

wordSuccessors :: Word64 -> Word32 -> [Word32]
wordSuccessors !w !a = if w > 0
  then a : wordSuccessors (w - 1) (a + 1)
  else []

wordSuccessorsM :: MonadPlus m => (Word32 -> a) -> Word64 -> Word32 -> m a
wordSuccessorsM f = go where
  go !w !a = if w > 0
    then mplus (return (f a)) (go (w - 1) (a + 1))
    else mzero
{-# INLINE wordSuccessorsM #-}

mask :: Word8 -> Word32
mask = complement . shiftR 0xffffffff . fromIntegral

p24 :: Word32
p24 = fromOctets' 10 0 0 0

p20 :: Word32
p20 = fromOctets' 172 16 0 0

p16 :: Word32
p16 = fromOctets' 192 168 0 0

mask8,mask4,mask12,mask20,mask28,mask16,mask10,mask24,mask32,mask15 :: Word32
mask4  = 0xF0000000
mask8  = 0xFF000000
mask10 = 0xFFC00000
mask12 = 0xFFF00000
mask15 = 0xFFFE0000
mask16 = 0xFFFF0000
mask20 = 0xFFFFF000
mask24 = 0xFFFFFF00
mask28 = 0xFFFFFFF0
mask32 = 0xFFFFFFFF

-- r1,r2,r3,r4,r5,r6 :: Word32
-- r1 = fromOctets' 0 0 0 0

macTextParser :: Maybe Char -> (Word64 -> Word64 -> Word64 -> Word64 -> Word64 -> Word64 -> a) -> AT.Parser a
macTextParser separator f = f
  <$> (AT.hexadecimal >>= limitSize)
  <*  parseSeparator
  <*> (AT.hexadecimal >>= limitSize)
  <*  parseSeparator
  <*> (AT.hexadecimal >>= limitSize)
  <*  parseSeparator
  <*> (AT.hexadecimal >>= limitSize)
  <*  parseSeparator
  <*> (AT.hexadecimal >>= limitSize)
  <*  parseSeparator
  <*> (AT.hexadecimal >>= limitSize)
  where
  parseSeparator = case separator of
    Just c -> AT.char c
    Nothing -> return 'x' -- character is unused
  limitSize i =
    if i > 255
      then fail "All octets in a mac address must be between 00 and FF"
      else return i

-- Unchecked invariant: each of these Word64s must be smaller
-- than 256.
unsafeWord48FromOctets :: Word64 -> Word64 -> Word64 -> Word64 -> Word64 -> Word64 -> Word48
unsafeWord48FromOctets a b c d e f =
    fromIntegral
  $ unsafeShiftL a 40 
  .|. unsafeShiftL b 32
  .|. unsafeShiftL c 24
  .|. unsafeShiftL d 16
  .|. unsafeShiftL e 8
  .|. f
{-# INLINE unsafeWord48FromOctets #-}

macFromText :: Maybe Char -> (Word64 -> Word64 -> Word64 -> Word64 -> Word64 -> Word64 -> a) -> Text -> Maybe a
macFromText separator f = rightToMaybe . macFromText' separator f
{-# INLINE macFromText #-}

macFromText' :: Maybe Char -> (Word64 -> Word64 -> Word64 -> Word64 -> Word64 -> Word64 -> a) -> Text -> Either String a
macFromText' separator f =
  AT.parseOnly (macTextParser separator f <* AT.endOfInput)
{-# INLINE macFromText' #-}

twoDigits :: ByteString
twoDigits = foldMap (BC8.pack . printf "%02d") $ enumFromTo (0 :: Int) 99
{-# NOINLINE twoDigits #-}

threeDigitsWord8 :: ByteString
threeDigitsWord8 = foldMap (BC8.pack . printf "%03d") $ enumFromTo (0 :: Int) 255
{-# NOINLINE threeDigitsWord8 #-}

twoHexDigits :: ByteString
twoHexDigits = foldMap (BC8.pack . printf "%02X") $ enumFromTo (0 :: Int) 255
{-# NOINLINE twoHexDigits #-}

twoHexDigitsLower :: ByteString
twoHexDigitsLower = foldMap (BC8.pack . printf "%02x") $ enumFromTo (0 :: Int) 255
{-# NOINLINE twoHexDigitsLower #-}

