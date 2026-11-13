#![no_main]
use edgeql_parser::tokenizer::Tokenizer;
use libfuzzer_sys::fuzz_target;

// The tokenizer as the Python bindings drive it: multi-word keyword merging and
// literal value parsing on, stopping at the first error.
fuzz_target!(|data: &str| {
    for tok in Tokenizer::new(data).validated_values().with_eof() {
        if tok.is_err() {
            break;
        }
    }
});
