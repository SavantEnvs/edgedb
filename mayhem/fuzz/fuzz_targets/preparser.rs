#![no_main]
use edgeql_parser::preparser::{full_statement, is_empty};
use libfuzzer_sys::fuzz_target;

// Statement splitter used by the REPL/protocol: feed the first part, and if the
// statement is incomplete resume with the continuation over the whole buffer.
fuzz_target!(|data: &[u8]| {
    let Some((&first, rest)) = data.split_first() else {
        return;
    };
    let split = first as usize % (rest.len() + 1);
    if let Err(cont) = full_statement(&rest[..split], None) {
        _ = full_statement(rest, Some(cont));
    }
    if let Ok(text) = std::str::from_utf8(rest) {
        _ = is_empty(text);
    }
});
