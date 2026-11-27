use serde::de::{Deserialize, Deserializer, Error, MapAccess, SeqAccess, Visitor};
use std::{collections::BTreeSet, fmt};

pub(super) struct UniqueJson;

impl<'de> Deserialize<'de> for UniqueJson {
    fn deserialize<D: Deserializer<'de>>(deserializer: D) -> Result<Self, D::Error> {
        deserializer.deserialize_any(UniqueVisitor)
    }
}

struct UniqueVisitor;

impl<'de> Visitor<'de> for UniqueVisitor {
    type Value = UniqueJson;

    fn expecting(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str("JSON with unique object fields")
    }

    fn visit_map<M: MapAccess<'de>>(self, mut map: M) -> Result<UniqueJson, M::Error> {
        let mut fields = BTreeSet::new();
        while let Some(key) = map.next_key::<String>()? {
            if !fields.insert(key.clone()) {
                return Err(M::Error::custom(format!("duplicate trace field: {key}")));
            }
            map.next_value::<UniqueJson>()?;
        }
        Ok(UniqueJson)
    }

    fn visit_seq<S: SeqAccess<'de>>(self, mut sequence: S) -> Result<UniqueJson, S::Error> {
        while sequence.next_element::<UniqueJson>()?.is_some() {}
        Ok(UniqueJson)
    }

    fn visit_bool<E: Error>(self, _: bool) -> Result<UniqueJson, E> {
        Ok(UniqueJson)
    }
    fn visit_i64<E: Error>(self, _: i64) -> Result<UniqueJson, E> {
        Ok(UniqueJson)
    }
    fn visit_u64<E: Error>(self, _: u64) -> Result<UniqueJson, E> {
        Ok(UniqueJson)
    }
    fn visit_f64<E: Error>(self, _: f64) -> Result<UniqueJson, E> {
        Ok(UniqueJson)
    }
    fn visit_str<E: Error>(self, _: &str) -> Result<UniqueJson, E> {
        Ok(UniqueJson)
    }
    fn visit_unit<E: Error>(self) -> Result<UniqueJson, E> {
        Ok(UniqueJson)
    }
}
