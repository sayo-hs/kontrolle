{-# LANGUAGE TypeData #-}

-- SPDX-License-Identifier: MPL-2.0

module Control.Monad.Effect.DynamicPromptStack where

import Control.Monad (ap, join, (>=>))
import Data.Extensible
import Data.Function ((&))
import Data.Functor.Identity (Identity (Identity), runIdentity)
import Data.Kind (Type)

type Effect = (Type -> Type) -> Type -> Type

data Evil :: Effect where
    Evil :: Evil f ()

data NonDet :: Effect where
    Choose :: NonDet f Bool
    Observe :: f [a] -> NonDet f [a]

data Except e :: Effect where
    Throw :: e -> Except e f a
    Try :: f a -> Except e f (Either e a)

data SomeEff :: Effect where
    SomeEff :: SomeEff f Int

type data Prompt = P (Type -> Type) [Effect] Effect

data Handler ps e where
    Handler ::
        (forall w esSend x. Membership w (P f u e) -> Membership esSend e -> e (Eff esSend) x -> Ctl w esSend x) ->
        Membership ps (P f u e) ->
        Handler ps e

type Handlers ps es = Rec es (ExtConst (Handler ps)) ()

newtype Eff es a = Eff {unEff :: forall ps. Ctl ps es a}

instance Functor (Eff es) where
    fmap f = (>>= pure . f)

instance Applicative (Eff es) where
    pure x = Eff $ Ctl \_ -> Pure x
    (<*>) = ap

instance Monad (Eff es) where
    Eff m >>= f = Eff $ Ctl \hs -> case unCtl m hs of
        Pure x -> unCtl (unEff (f x)) hs
        Freer u k -> Freer u (k >=> f)

trans :: (forall ps. Handlers ps es' -> Handlers ps es) -> Eff es a -> Eff es' a
trans f (Eff m) =
    Eff $ Ctl \hs ->
        case unCtl m (f hs) of
            Pure x -> Pure x
            Freer u k -> Freer u $ trans f . k

transCtl :: (forall ps'. Handlers ps' es' -> Handlers ps' es) -> Ctl ps es a -> Ctl ps es' a
transCtl f (Ctl m) =
    Ctl \hs -> case m (f hs) of
        Pure x -> Pure x
        Freer u k -> Freer u $ trans f . k

raise :: Eff es a -> Eff (e : es) a
raise = trans \(_ :* hs) -> hs

raiseUnder :: Eff (e : es) a -> Eff (e : e' : es) a
raiseUnder = trans \(h :* _ :* hs) -> h :* hs

swap :: Handlers ps (e1 : e2 : es) -> Handlers ps (e2 : e1 : es)
swap (h1 :* h2 :* es) = h2 :* h1 :* es

newtype Ctl (ps :: [Prompt]) (es :: [Effect]) a = Ctl {unCtl :: Handlers ps es -> CtlF ps es a}

data CtlF ps es a
    = Pure a
    | forall x. Freer (Union ps ControlPrim x) (x -> Eff es a)

data ControlPrim (p :: Prompt) a where
    Control :: (forall es x. Membership es e -> (a -> Eff es (f x)) -> Eff es (f x)) -> ControlPrim (P f u e) a
    Control0 :: (forall x. (a -> Eff u (f x)) -> Eff u (f x)) -> ControlPrim (P f u e) a

weakenPrompt :: Handler ps e -> Handler (p : ps) e
weakenPrompt (Handler h i) = Handler h (weakenMembership i)

liftPrompt :: forall p ps es. Handlers ps es -> Handlers (p : ps) es
liftPrompt = mapRec $ ExtConst . weakenPrompt . getExtConst

send :: Membership es e -> e (Eff es) a -> Eff es a
send i e = Eff $ Ctl \hs -> case at i hs of
    ExtConst (Handler h i') -> unCtl (h i' i e) hs

perform :: (e :> es) => e (Eff es) a -> Eff es a
perform = send membership

control :: Membership ps (P f u e) -> (forall es x. Membership es e -> (a -> Eff es (f x)) -> Eff es (f x)) -> Ctl ps esSend a
control i f = Ctl \_ -> Freer (inject i $ Control f) pure

control0 :: Membership ps (P f u e) -> (forall x. (a -> Eff u (f x)) -> Eff u (f x)) -> Ctl ps es a
control0 i f = Ctl \_ -> Freer (inject i $ Control0 f) pure

pureCtl :: a -> Ctl ps es a
pureCtl x = Ctl \_ -> Pure x

bindCtl :: Ctl ps es a -> (a -> Eff es b) -> Ctl ps es b
bindCtl (Ctl m) f = Ctl \hs -> case m hs of
    Pure x -> unCtl (unEff $ f x) hs
    Freer u k -> Freer u (k >=> f)

fmapCtl :: (a -> b) -> Ctl ps es a -> Ctl ps es b
fmapCtl f m = m `bindCtl` (pure . f)

delimit :: Membership ps (P f u e) -> Membership es e -> Ctl ps es (f a) -> Ctl ps es (f a)
delimit i ie (Ctl m) = Ctl \hs ->
    case m hs of
        Pure x -> Pure x
        Freer ctls k -> case project i ctls of
            Just (Control ctl) -> unCtl (unEff $ ctl ie k) hs
            _ -> Freer ctls k

data Control (f :: Type -> Type) :: Effect where
    Capture :: (forall es x. Membership es (Control f) -> (a -> Eff es (f x)) -> Eff es (f x)) -> Control f m a
    Delimit :: m (f a) -> Control f m (f a)

runControl :: Eff (Control f : es) (f a) -> Eff es (f a)
runControl = interpretShallow \i ie -> \case
    Capture f -> control i f
    Delimit (Eff m) -> delimit i ie m

data Control0 (f :: Type -> Type) es :: Effect where
    Capture0 :: (forall x. (a -> Eff (Control0 f es : es) (f x)) -> Eff (Control0 f es : es) (f x)) -> Control0 f es m a

runControl0 :: Eff (Control0 f es : es) (f a) -> Eff es (f a)
runControl0 = interpretShallow \i _ -> \case
    Capture0 f -> control0 i f

interpretShallow ::
    (forall w esSend x. Membership w (P f (e : es) e) -> Membership esSend e -> e (Eff esSend) x -> Ctl w esSend x) ->
    Eff (e : es) (f a) ->
    Eff es (f a)
interpretShallow h (Eff m) =
    Eff $ Ctl \hs ->
        let hs' = ExtConst (Handler h membership0) :* liftPrompt hs
         in case unCtl m hs' of
                Pure x -> Pure x
                Freer ctls k -> case ctls of
                    Here (Control ctl) -> unCtl (unEff $ interpretShallow h $ ctl membership0 k) hs
                    Here (Control0 ctl) -> unCtl (unEff $ interpretShallow h $ ctl k) hs
                    There u -> Freer u $ interpretShallow h . k

interpret ::
    (forall w esSend x. Membership w (P f es e) -> Membership esSend e -> e (Eff esSend) x -> Ctl w esSend x) ->
    Eff (e : es) (f a) ->
    Eff es (f a)
interpret h (Eff m) =
    Eff $ Ctl \hs ->
        let hs' = ExtConst (Handler h membership0) :* liftPrompt hs
         in case unCtl m hs' of
                Pure x -> Pure x
                Freer ctls k -> case ctls of
                    Here (Control ctl) -> unCtl (unEff $ interpret h $ ctl membership0 k) hs
                    Here (Control0 ctl) -> unCtl (unEff $ ctl $ interpret h . k) hs
                    There u -> Freer u $ interpret h . k

runPure :: Eff '[] a -> a
runPure (Eff m) = case unCtl m Nil of
    Pure x -> x
    Freer u _ -> nil u

runSomeEff :: (Except String :> es) => Eff (SomeEff : es) a -> Eff es a
runSomeEff =
    fmap runIdentity
        . interpret (\i _ SomeEff -> control0 i \_ -> perform $ Throw "uncaught")
        . fmap Identity

runExcept :: Eff (Except e : es) a -> Eff es (Either e a)
runExcept m =
    Right <$> m & interpret \i ie -> \case
        Throw e -> control i \_ _ -> pure $ Left e
        Try n -> delimit i ie $ unEff $ Right <$> n

-- >>> testE
-- Left "uncaught"

testE :: Either String (Either String Int)
testE = runPure $ runExcept $ runSomeEff do
    perform $ Try $ perform SomeEff

runNonDet :: Eff (NonDet : es) [a] -> Eff es [a]
runNonDet =
    interpret \i ie -> \case
        Choose -> control i \ie' k -> do
            xs <- send ie' $ Observe $ k False
            ys <- send ie' $ Observe $ k True
            pure $ xs ++ ys
        Observe n -> delimit i ie $ unEff n

-- >>> test
-- [Identity [(False,False),(False,True),(True,False),(True,True)]]

test :: [Identity [(Bool, Bool)]]
test = runPure $ runNonDet do
    xs <- perform $ Observe do
        b1 <- perform Choose
        b2 <- perform Choose
        pure [(b1, b2)]
    pure [Identity xs]

data Reader r :: Effect where
    Ask :: Reader r f r

-- Local :: (r -> r) -> f a -> Reader r f a

runReader :: r -> Eff (Reader r : es) a -> Eff es a
runReader r =
    fmap runIdentity
        . interpret
            ( \_ _ -> \case
                Ask -> pureCtl r
                -- Local f m -> unEff $ runReader (f r) (pull i m)
            )
        . fmap Identity

runEvil :: Eff (Evil : es) a -> Eff es (Eff es a)
runEvil = interpret (\i _ Evil -> control0 i \k -> pure $ join $ k ()) . fmap pure

-- >>> testNSR
-- (1,2)

testNSR :: (Int, Int)
testNSR = runPure do
    let prog = do
            x :: Int <- perform Ask
            perform Evil
            y :: Int <- perform Ask
            pure (x, y)

    k <- runReader @Int 1 $ runEvil prog

    runReader @Int 2 k
