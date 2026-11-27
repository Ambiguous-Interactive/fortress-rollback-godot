const V2: &str = "d124c89080004d96971a629bb0427056ee1805e3";
const V6: &str = "25e8020d1a5fd40c4f16b37f97b5ec5329a8566d";

pub fn compiled() -> Result<&'static str, &'static str> {
    let revision = option_env!("FORTRESS_ORACLE_SOURCE_REVISION").unwrap_or(V2);
    let expected_wire = match revision {
        V2 => 2,
        V6 => 6,
        _ => return Err("unregistered Fortress source revision"),
    };
    if fortress_rollback::PROTOCOL_VERSION != expected_wire {
        return Err("compiled Fortress wire version differs from its source revision");
    }
    Ok(revision)
}
