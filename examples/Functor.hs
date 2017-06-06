data Maybe a = Nothing | Just a
class Functor (f :: Type -> Type) where
  map :: forall a b. (a -> b) -> f a -> f b
instance Functor Maybe where
  map = \f m ->
    case m of
      Nothing -> Nothing
      Just a -> Just (f a)
not = \b -> case b of
              True -> False
              False -> True
demo = map not (Just True)