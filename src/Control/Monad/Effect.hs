{-# LANGUAGE AllowAmbiguousTypes #-}
{-# LANGUAGE DerivingVia #-}
{-# LANGUAGE FunctionalDependencies #-}
{-# LANGUAGE QuantifiedConstraints #-}
{-# LANGUAGE TypeData #-}
{-# LANGUAGE TypeFamilyDependencies #-}
{-# LANGUAGE UndecidableInstances #-}
{-# HLINT ignore "Avoid lambda" #-}
{-# OPTIONS_GHC -Wno-unrecognised-pragmas #-}

-- SPDX-License-Identifier: MPL-2.0

module Control.Monad.Effect where

import Control.Monad (join)
import Control.Monad.MultiPrompt.Formal (
    Control (..),
    CtlT (..),
    PromptFrame (..),
    StackUnion (..),
    Sub,
    cmapCtlT,
    runCtlT,
    under,
 )
import Control.Monad.MultiPrompt.Formal qualified as C
import Control.Monad.Trans.Freer
import Control.Monad.Trans.Reader (ReaderT (ReaderT), runReaderT)
import Data.Coerce (Coercible, coerce)
import Data.Function (fix)
import Data.Functor.Const (Const (Const), getConst)
import Data.Functor.Identity (Identity)
import Data.Kind (Type)
import Data.Proxy (Proxy (Proxy))

type Effect = (Type -> Type) -> Type -> Type

infixr 6 :+
infixr 6 :/

type e :+ es = E e : es
type e :/ es = P e : es

type data Frame = E Effect | P (Type -> Type)

type family Prompts m es where
    Prompts m (_ :+ es) = Prompts m es
    Prompts m (f :/ es) = Prompt f (Env m es) : Prompts m es
    Prompts _ '[] = '[]

type family FrameList es where
    FrameList (e :+ es) = E e : FrameList es
    FrameList (ans :/ es) = P ans : FrameList es
    FrameList '[] = '[]

newtype Env m es = Env {unEnv :: Handlers m es es}

-- | A effect handler.
data Handler (m :: Type -> Type) (w :: [Frame]) (e :: Effect) (u :: [Frame])
    = Handler
    { handler :: forall x. e (EffCtlT (Prompts m u) w m) x -> EffCtlT (Prompts m u) u m x
    , envOnHandler :: Handlers m w u
    }

-- | Vector of handlers.
data Handlers (m :: Type -> Type) (w :: [Frame]) (es :: [Frame]) where
    ConsHandler :: Handler m w e es -> Handlers m w es -> Handlers m w (e :+ es)
    ConsPrompt :: Handlers m w es -> Handlers m w (ans :/ es)
    Nil :: Handlers w m '[]

-- | An effect monad built on top of a multi-prompt/control monad.
newtype EffT es m a = EffT {unEffT :: CtlT (Prompts m es) (Env m es) m a}
    deriving (Functor, Applicative, Monad)

newtype EffCtlT ps es m a = EffCtlT {unEffCtlT :: CtlT ps (Env m es) m a}
    deriving (Functor, Applicative, Monad)

class EnvFunctor (e :: Effect) where
    cmapEnv :: (Monad m) => (Env m es -> Env m es') -> e (EffCtlT ps es' m) a -> e (EffCtlT ps es m) a
    fromCtlH :: e (EffCtlT (Prompts m es) es m) a -> e (EffT es m) a
    toCtlH :: e (EffT es m) a -> e (EffCtlT (Prompts m es) es m) a

class EnvFunctors es where
    mapHandlers :: (Monad m) => (Env m w -> Env m w') -> Handlers m w es -> Handlers m w' es

instance EnvFunctors '[] where
    mapHandlers _ _ = Nil

instance (EnvFunctor e, EnvFunctors es) => EnvFunctors (E e : es) where
    mapHandlers f (ConsHandler (Handler h r) hs) = ConsHandler (Handler (h . cmapEnv f) $ mapHandlers f r) (mapHandlers f hs)

instance (EnvFunctors es) => EnvFunctors (P a : es) where
    mapHandlers f (ConsPrompt hs) = ConsPrompt $ mapHandlers f hs

mapEnv :: (EnvFunctors es', Monad m) => (Handlers m es es -> Handlers m es es') -> Env m es -> Env m es'
mapEnv f (Env hs) = Env $ mapHandlers (mapEnv f) (f hs)

mapEnvShallow :: (EnvFunctors es, Monad m) => (Handlers m es' es -> Handlers m es' es') -> Env m es -> Env m es'
mapEnvShallow f (Env hs) = Env $ f $ mapHandlers (mapEnvShallow f) hs

(!:) ::
    (EnvFunctors es, Monad m) =>
    (forall x. e (EffCtlT (Prompts m es) (e :+ es) m) x -> EffCtlT (Prompts m es) es m x) ->
    Env m es ->
    Env m (e :+ es)
h !: Env r = Env $ ConsHandler (Handler h (mapHandlers (h !:) r)) (mapHandlers (h !:) r)

class IsFrame e where
    dropHandler :: (Monad m) => Handlers m w (e : es) -> Handlers m w es

instance IsFrame (E e) where
    dropHandler (ConsHandler _ hs) = hs

instance IsFrame (P f) where
    dropHandler (ConsPrompt hs) = hs

-- | Type-level search over elements in a vector.
class (Monad m) => Elem e (es :: [Frame]) m u | e es -> u where
    membership :: Membership e es m u

data Membership e es m u = Membership
    { getHandler :: forall w. Handlers m w es -> Handler m w e u
    , promptEvidence :: Sub (Prompts m u) (Prompts m es)
    , dropUnder :: forall w. Handlers m w es -> Handlers m w u
    }

instance (Monad m) => Elem e (e :+ es) m es where
    membership =
        Membership
            { getHandler = \(ConsHandler h _) -> h
            , promptEvidence = C.sub Proxy
            , dropUnder = dropHandler
            }

instance {-# OVERLAPPABLE #-} (Elem e es m u) => Elem e (e' :+ es) m u where
    membership =
        let ms = membership @e @es @m @u
         in Membership
                { getHandler = \(ConsHandler _ hs) -> getHandler membership hs
                , promptEvidence = promptEvidence ms
                , dropUnder = dropUnder ms . dropHandler
                }

instance (Elem e es m u) => Elem e (f :/ es) m u where
    membership =
        Membership
            { getHandler = \(ConsPrompt hs) -> getHandler membership hs
            , promptEvidence =
                let ev = promptEvidence $ membership @e @es @m @u
                 in C.Sub (C.There . C.weaken ev) \case
                        C.Here _ -> Nothing
                        C.There u -> C.strengthen ev u
            , dropUnder = dropUnder (membership @e @es @m @u) . dropHandler
            }

sendCtl ::
    forall e ps es m u a.
    (Monad m, EnvFunctors u, EnvFunctors es) =>
    Sub (Prompts m u) ps ->
    Membership e es m u ->
    e (EffCtlT (Prompts m u) es m) a ->
    EffCtlT ps es m a
sendCtl sub i e =
    EffCtlT $ CtlT $ FreerT $ ReaderT \r@(Env hs) ->
        let Handler h r' = getHandler i hs
         in (`runReaderT` r)
                . runFreerT
                . unCtlT
                . under
                    sub
                    (Env . envOnHandler . getHandler i . mapHandlers (mapEnv $ dropUnder i) . unEnv)
                    (Env $ mapHandlers (mapEnv $ dropUnder i) r')
                . unEffCtlT
                $ h e

send :: forall e es m u a. (Monad m, EnvFunctors u, EnvFunctor e, EnvFunctors es) => Membership e es m u -> e (EffT u m) a -> EffT es m a
send i e = EffT . unEffCtlT $ sendCtl (promptEvidence i) i (cmapEnv (mapEnv $ dropUnder i) $ toCtlH e)

interpret ::
    (Monad m, EnvFunctor e, EnvFunctors es) =>
    (forall x. e (EffT (e :+ es) m) x -> EffT es m x) ->
    EffT (e :+ es) m a ->
    EffT es m a
interpret f (EffT m) =
    EffT $ cmapCtlT (\r -> (EffCtlT . unEffT . f . fromCtlH) !: r) m

prompt :: (Monad m, EnvFunctors es) => EffT (f :/ es) m (f a) -> EffT es m (f a)
prompt (EffT m) = EffT $ C.prompt (mapEnv ConsPrompt) m

interpretBy ::
    forall e a f es m.
    (Monad m, EnvFunctor e, EnvFunctors es) =>
    (a -> EffT es m (f a)) ->
    (forall x y. e (EffT (e :+ f :/ es) m) x -> (x -> EffT es m (f y)) -> EffT es m (f y)) ->
    EffT (e :+ f :/ es) m a ->
    EffT es m (f a)
interpretBy ret hdl m =
    prompt $ interpret (\e -> control0 (C.Sub id Just) \k -> hdl e k) (m >>= raiseEP . ret)

raise :: (Monad m, EnvFunctors es) => EffT es m a -> EffT (e :+ es) m a
raise = EffT . cmapCtlT (mapEnv dropHandler) . unEffT

raisePrompt :: (Monad m, EnvFunctors es) => EffT es m a -> EffT (a' :/ es) m a
raisePrompt = EffT . cmapCtlT (mapEnv dropHandler) . C.raise . unEffT

raiseEP :: (Monad m, EnvFunctors es) => EffT es m a -> EffT (e :+ a' :/ es) m a
raiseEP = EffT . cmapCtlT (mapEnv (dropHandler . dropHandler)) . C.raise . unEffT

control0 ::
    forall f u es m a.
    (Monad m) =>
    C.Sub
        (Prompts m (f :/ u))
        (Prompts m es) ->
    (forall x. (a -> EffT u m (f x)) -> EffT u m (f x)) ->
    EffT es m a
control0 i f = EffT $ C.control0 i \k -> unEffT $ f $ EffT . k

runPure :: EffT '[] Identity a -> a
runPure = C.runPure (Env Nil) . unEffT

runEffT :: (Functor f) => EffT '[] f a -> f a
runEffT = runCtlT (Env Nil) . unEffT

newtype FirstOrder (e :: Effect) es a = FirstOrder (e es a)

instance (forall es es' x. Coercible (e es x) (e es' x)) => EnvFunctor (FirstOrder e) where
    cmapEnv _ = coerce
    fromCtlH = coerce
    toCtlH = coerce

perform :: (Elem e es m u, EnvFunctors u, EnvFunctor e, EnvFunctors es) => e (EffT u m) a -> EffT es m a
perform = send membership

-- >>> test
-- Left 3

test :: Either Int ()
test = runPure . runExc $ perform $ Throw @Int 3

data Reader r :: Effect where
    Ask :: Reader r es r
    Local :: (r -> r) -> m a -> Reader r m a

instance EnvFunctor (Reader r) where
    cmapEnv f = \case
        Ask -> Ask
        Local g m -> Local g $ EffCtlT . cmapCtlT f $ unEffCtlT m
    fromCtlH = coerce
    toCtlH = coerce

runReader :: (Monad m, EnvFunctors es) => r -> EffT (Reader r :+ es) m a -> EffT es m a
runReader r = interpret \case
    Ask -> pure r
    Local f m -> runReader (f r) m

runReader1 :: (Monad m, EnvFunctors es) => EffT (Reader Int :+ es) m a -> EffT es m a
runReader1 = runReader 1

runReader2 :: (Monad m, EnvFunctors es) => EffT (Reader Int :+ es) m a -> EffT es m a
runReader2 = runReader 2

data Evil :: Effect where
    Evil :: Evil es ()

deriving via FirstOrder Evil instance EnvFunctor Evil

runEvil :: (Monad m, EnvFunctors es) => EffT (Evil :+ Const (EffT es m a) :/ es) m a -> EffT es m (EffT es m a)
runEvil = fmap getConst . interpretBy (pure . Const . pure) \Evil k -> pure $ Const $ getConst =<< k ()

-- >>> evilTest
-- 2

evilTest :: Int
evilTest = runPure do
    m <- runReader1 $ runEvil do
        _ <- perform $ Ask @Int
        perform Evil
        perform $ Ask @Int
    runReader2 m

data Exc e :: Effect where
    Throw :: e -> Exc e m a
    Catch :: m a -> (e -> m a) -> Exc e m a

instance EnvFunctor (Exc e) where
    cmapEnv f = \case
        Throw e -> Throw e
        Catch m hdl -> Catch (EffCtlT . cmapCtlT f . unEffCtlT $ m) (EffCtlT . cmapCtlT f . unEffCtlT . hdl)
    fromCtlH = coerce
    toCtlH = coerce

runExc :: (Monad m, EnvFunctors es) => EffT (Exc e :+ Either e :/ es) m a -> EffT es m (Either e a)
runExc =
    interpretBy
        (pure . Right)
        ( \case
            Throw e -> \_ -> pure $ Left e
            Catch m hdl -> \k -> do
                x <-
                    flip fix m \f n ->
                        runExc n >>= \case
                            Left e -> f $ hdl e
                            Right x -> pure x
                k x
        )

-- >>> excTest
-- Left "test"

excTest :: Either String Int
excTest = runPure $ runExc do
    perform @(Exc String) $
        Catch
            (perform $ Throw "test")
            undefined
