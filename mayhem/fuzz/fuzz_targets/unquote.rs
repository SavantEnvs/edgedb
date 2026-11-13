#![no_main]
use edgeql_parser::helpers::{quote_name, quote_string, unquote_string};
use libfuzzer_sys::fuzz_target;

// unquote_string only accepts the text of a string token (its quotes included), so the
// input is turned into one with quote_string. The result is not asserted on:
// quote_string writes C1 controls as `\x80`..`\x9f` escapes that unquote_string rejects.
fuzz_target!(|data: &str| {
    _ = quote_name(data);
    _ = unquote_string(&quote_string(data));
});
