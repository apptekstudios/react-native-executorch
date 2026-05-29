/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 * All rights reserved.
 *
 * This source code is licensed under the BSD-style license found in the
 * LICENSE file in the root directory of this source tree.
 */
// @lint-ignore-every LICENSELINT

// Local
#include <pytorch/tokenizers/pre_tokenizer.h>
#include <unicode.h>

// Standard
#include <algorithm>
#include <cassert>
#include <cstddef>
#include <iterator>
#include <memory>
#include <stdexcept>
#include <string>
#include <utility>
#include <vector>

// Third Party
#include <nlohmann/json.hpp>

using json = nlohmann::json;

namespace tokenizers {

// PreTokenizerConfig //////////////////////////////////////////////////////////

PreTokenizerConfig::PreTokenizerConfig(std::string type)
    : type(std::move(type)) {}

PreTokenizer::Ptr PreTokenizerConfig::create() const {
  // NOTE: These types must line up with the type strings found in the
  //  tokenizers library
  //  https://github.com/huggingface/tokenizers/blob/main/tokenizers/src/pre_tokenizers/mod.rs#L73
  if (type == "Split") {
    if (!pattern) {
      throw std::runtime_error(
          "Missing pattern for PreTokenizer of type Split");
    }

    // Validate behavior parameter, if missing set to default "Removed"
    std::string behavior_str = behavior ? *behavior : "Removed";
    if (behavior_str != "MergedWithPrevious" && behavior_str != "Isolated" &&
        behavior_str != "Removed") {
      throw std::runtime_error(
          "Unsupported behavior '" + behavior_str +
          "' for Split PreTokenizer. Only 'MergedWithPrevious', 'Removed' and "
          "'Isolated' are supported.");
    }

    // Validate invert parameter
    const bool invert_flag = invert ? *invert : false;
    const bool delimiter_flag = is_delimiter ? *is_delimiter : false;
    if (invert_flag && delimiter_flag) {
      throw std::runtime_error("invert=true is not supported for Split "
                               "PreTokenizer with a String pattern.");
    }

    return PreTokenizer::Ptr(
        new RegexPreTokenizer(*pattern, delimiter_flag, behavior_str));
  }
  if (type == "Digits") {
    if (individual_digits) {
      return PreTokenizer::Ptr(new DigitsPreTokenizer(*individual_digits));
    }
    return PreTokenizer::Ptr(new DigitsPreTokenizer());
  }
  if (type == "ByteLevel") {
    if (add_prefix_space && pattern) {
      return PreTokenizer::Ptr(
          new ByteLevelPreTokenizer(*add_prefix_space, *pattern));
    }
    if (add_prefix_space) {
      return PreTokenizer::Ptr(new ByteLevelPreTokenizer(*add_prefix_space));
    }
    if (pattern) {
      return PreTokenizer::Ptr(new ByteLevelPreTokenizer(*pattern));
    }
    return PreTokenizer::Ptr(new ByteLevelPreTokenizer());
  }
  if (type == "Sequence") {
    if (!pretokenizers || pretokenizers->empty()) {
      throw std::runtime_error(
          "Missing pretokenizers for PreTokenizer of type Sequence");
    }
    std::vector<PreTokenizer::Ptr> pretoks;
    std::transform(pretokenizers->begin(), pretokenizers->end(),
                   std::back_inserter(pretoks),
                   [](const PreTokenizerConfig &cfg) { return cfg.create(); });
    return PreTokenizer::Ptr(new SequencePreTokenizer(pretoks));
  }
  if (type == "BertPreTokenizer") {
    return PreTokenizer::Ptr(new BertPreTokenizer());
  }
  if (type == "Metaspace") {
    std::string rep = replacement.value_or("\xe2\x96\x81");
    MetaspacePreTokenizer::PrependScheme scheme =
        MetaspacePreTokenizer::PrependScheme::Always;
    if (prepend_scheme) {
      scheme = MetaspacePreTokenizer::parse_prepend_scheme(*prepend_scheme);
    } else if (add_prefix_space) {
      // Legacy serialisation: add_prefix_space=false => Never, true => Always.
      scheme = *add_prefix_space ? MetaspacePreTokenizer::PrependScheme::Always
                                 : MetaspacePreTokenizer::PrependScheme::Never;
    }
    return PreTokenizer::Ptr(
        new MetaspacePreTokenizer(rep, scheme, split.value_or(true)));
  }
  throw std::runtime_error("Unsupported PreTokenizer type: " + type);
}

PreTokenizerConfig &PreTokenizerConfig::parse_json(const json &json_config) {
  type = json_config.at("type");
  if (type == "Split") {
    try {
      pattern = json_config.at("pattern").at("Regex");
      is_delimiter = false;
    } catch (json::out_of_range &) {
      // "Regex" is not there, check "String", which is a delimiter
      std::string delimiter = json_config.at("pattern").at("String");
      // For string patterns, escape regex special characters to treat them as
      // literal strings (same as Rust's regex::escape)
      pattern = IRegex::escape(delimiter);
      is_delimiter = true;
    }

    // Parse behavior and invert fields
    try {
      behavior = json_config.at("behavior");
    } catch (json::out_of_range &) {
      // behavior is optional, default to empty string
    }

    try {
      invert = json_config.at("invert");
    } catch (json::out_of_range &) {
      // invert is optional, default to false
    }
  } else if (type == "Digits") {
    try {
      individual_digits = json_config.at("individual_digits");
    } catch (json::out_of_range &) {
    }
  } else if (type == "ByteLevel") {
    try {
      add_prefix_space = json_config.at("add_prefix_space");
    } catch (json::out_of_range &) {
    }
    // TODO: trim_offsets, use_regex
  } else if (type == "Sequence") {
    pretokenizers = std::vector<PreTokenizerConfig>();
    for (const auto &entry : json_config.at("pretokenizers")) {
      pretokenizers->push_back(PreTokenizerConfig().parse_json(entry));
    }
  } else if (type == "BertPreTokenizer") {
    // No tunable parameters.
  } else if (type == "Metaspace") {
    if (json_config.contains("replacement") &&
        !json_config.at("replacement").is_null()) {
      replacement = json_config.at("replacement").get<std::string>();
    }
    // HF historically emits either `prepend_scheme` (string) or the older
    // `add_prefix_space` (bool); accept both.
    if (json_config.contains("prepend_scheme") &&
        !json_config.at("prepend_scheme").is_null()) {
      prepend_scheme = json_config.at("prepend_scheme").get<std::string>();
    }
    if (json_config.contains("add_prefix_space") &&
        !json_config.at("add_prefix_space").is_null()) {
      add_prefix_space = json_config.at("add_prefix_space").get<bool>();
    }
    if (json_config.contains("split") && !json_config.at("split").is_null()) {
      split = json_config.at("split").get<bool>();
    }
  } else {
    throw std::runtime_error("Unsupported PreTokenizer type: " + type);
  }
  return *this;
}

// RegexPreTokenizer ///////////////////////////////////////////////////////////

std::unique_ptr<IRegex>
RegexPreTokenizer::create_regex_(const std::string &pattern) {
  assert(!pattern.empty());
  auto regex_result = create_regex(pattern);
  if (!regex_result.ok()) {
    throw std::runtime_error(
        "Error: " + std::to_string(static_cast<int>(regex_result.error())));
  }
  return std::move(regex_result.get());
}

std::vector<std::string>
RegexPreTokenizer::pre_tokenize(const std::string &input) const {
  if (!regex_) {
    return {};
  }

  std::vector<std::string> results;
  auto matches = regex_->find_all(input);

  if (!is_delimiter_) {
    // Original behavior: return the matches themselves
    for (const auto &match : matches) {
      results.push_back(input.substr(match.start, match.end - match.start));
    }
  } else {
    // Delimiter behavior
    if (matches.empty()) {
      // No matches found, return the entire input
      results.push_back(input);
      return results;
    }

    if (behavior_ == "MergedWithPrevious") {
      // MergedWithPrevious: Include delimiter with previous token
      // Example: "the-final--countdown" with delimiter "-"
      // -> ["the-", "final-", "-", "countdown"]
      size_t last_end = 0;

      for (size_t i = 0; i < matches.size(); ++i) {
        const auto &match = matches[i];

        // Add text before the match plus the delimiter
        if (match.start > last_end) {
          std::string token = input.substr(last_end, match.end - last_end);
          results.push_back(token);
        } else {
          // Only delimiter, no preceding text
          std::string delimiter =
              input.substr(match.start, match.end - match.start);
          results.push_back(delimiter);
        }

        last_end = match.end;
      }

      // Add remaining text after the last match (if any)
      if (last_end < input.length()) {
        results.push_back(input.substr(last_end));
      }
    } else if (behavior_ == "Isolated") {
      // Isolated: Keep delimiters as separate tokens
      // Example: "the-final--countdown" with delimiter "-"
      // -> ["the", "-", "final", "-", "-", "countdown"]
      size_t last_end = 0;
      for (const auto &match : matches) {
        // Add text before the match (if any)
        if (match.start > last_end) {
          results.push_back(input.substr(last_end, match.start - last_end));
        }

        // Add the delimiter itself as a separate token
        std::string delimiter =
            input.substr(match.start, match.end - match.start);
        results.push_back(delimiter);

        last_end = match.end;
      }

      // Add remaining text after the last match (if any)
      if (last_end < input.length()) {
        results.push_back(input.substr(last_end));
      }
    } else if (behavior_ == "Removed" || behavior_.empty()) {
      // Default delimiter behavior (split on delimiters, remove delimiters)
      size_t last_end = 0;
      for (const auto &match : matches) {
        // Add text before the match (if any)
        if (match.start > last_end) {
          results.push_back(input.substr(last_end, match.start - last_end));
        }
        last_end = match.end;
      }

      // Add remaining text after the last match (if any)
      if (last_end < input.length()) {
        results.push_back(input.substr(last_end));
      }
    }
  }
  return results;
}

// ByteLevelPreTokenizer ///////////////////////////////////////////////////////

//////////////////
// Impl Details //
//////////////////
namespace {

// Standard GPT2 regex
// https://github.com/openai/gpt-2/blob/master/src/encoder.py#L53
constexpr char GPT2_EXPR[] =
    R"('s|'t|'re|'ve|'m|'ll|'d| ?\p{L}+| ?\p{N}+| ?[^\s\p{L}\p{N}]+|\s+(?!\S)|\s+)";

} // namespace

//////////////////
// Construction //
//////////////////

ByteLevelPreTokenizer::ByteLevelPreTokenizer(bool add_prefix_space,
                                             const std::string &pattern)
    : pattern_(pattern.empty() ? GPT2_EXPR : pattern),
      add_prefix_space_(add_prefix_space) {}

std::vector<std::string>
ByteLevelPreTokenizer::pre_tokenize(const std::string &input) const {
  // Add the prefix space if configured to do so.
  std::string formatted_input = input;
  if (add_prefix_space_ && !formatted_input.empty() &&
      formatted_input[0] != ' ') {
    formatted_input.insert(formatted_input.begin(), ' ');
  }

  return unicode_regex_split(formatted_input, {pattern_});
}

// SequencePreTokenizer ////////////////////////////////////////////////////////

SequencePreTokenizer::SequencePreTokenizer(
    std::vector<PreTokenizer::Ptr> pre_tokenizers)
    : pre_tokenizers_(std::move(pre_tokenizers)) {}

std::vector<std::string>
SequencePreTokenizer::pre_tokenize(const std::string &input) const {
  std::vector<std::string> pieces{std::string(input)};
  for (const auto &pre_tokenizer : pre_tokenizers_) {
    std::vector<std::string> new_pieces;
    for (const auto &piece : pieces) {
      for (const auto &subpiece : pre_tokenizer->pre_tokenize(piece)) {
        new_pieces.push_back(subpiece);
      }
    }
    pieces = std::move(new_pieces);
  }
  return pieces;
}

// BertPreTokenizer ////////////////////////////////////////////////////////////
// Port of huggingface/tokenizers src/pre_tokenizers/bert.rs. Two passes:
//   1. Split on whitespace, drop the whitespace.
//   2. For each run, isolate every punctuation codepoint as its own token.

namespace {

inline bool bert_is_whitespace(uint32_t cp) {
  if (cp == ' ' || cp == '\t' || cp == '\n' || cp == '\r') {
    return true;
  }
  return unicode_cpt_flags(cp).is_whitespace;
}

// HF Rust `is_bert_punc`: ASCII punctuation OR Unicode \p{P}.
inline bool bert_is_punctuation(uint32_t cp) {
  // ASCII punctuation as defined by Rust's char::is_ascii_punctuation:
  // U+0021-U+002F, U+003A-U+0040, U+005B-U+0060, U+007B-U+007E.
  if ((cp >= 0x21 && cp <= 0x2F) || (cp >= 0x3A && cp <= 0x40) ||
      (cp >= 0x5B && cp <= 0x60) || (cp >= 0x7B && cp <= 0x7E)) {
    return true;
  }
  return unicode_cpt_flags(cp).is_punctuation;
}

inline std::string cpts_to_utf8(const std::vector<uint32_t> &cpts) {
  std::string result;
  result.reserve(cpts.size());
  for (uint32_t cp : cpts) {
    result += unicode_cpt_to_utf8(cp);
  }
  return result;
}

} // namespace

std::vector<std::string>
BertPreTokenizer::pre_tokenize(const std::string &input) const {
  std::vector<std::string> result;
  if (input.empty()) {
    return result;
  }

  const auto cpts = unicode_cpts_from_utf8(input);

  // Pass 1: collect non-whitespace runs.
  std::vector<std::vector<uint32_t>> runs;
  std::vector<uint32_t> cur;
  for (uint32_t cp : cpts) {
    if (bert_is_whitespace(cp)) {
      if (!cur.empty()) {
        runs.push_back(std::move(cur));
        cur.clear();
      }
    } else {
      cur.push_back(cp);
    }
  }
  if (!cur.empty()) {
    runs.push_back(std::move(cur));
  }

  // Pass 2: within each run, break out punctuation as its own token.
  for (const auto &run : runs) {
    std::vector<uint32_t> chunk;
    for (uint32_t cp : run) {
      if (bert_is_punctuation(cp)) {
        if (!chunk.empty()) {
          result.push_back(cpts_to_utf8(chunk));
          chunk.clear();
        }
        result.push_back(unicode_cpt_to_utf8(cp));
      } else {
        chunk.push_back(cp);
      }
    }
    if (!chunk.empty()) {
      result.push_back(cpts_to_utf8(chunk));
    }
  }

  return result;
}

// MetaspacePreTokenizer //////////////////////////////////////////////////////
// Port of huggingface/tokenizers src/pre_tokenizers/metaspace.rs. Behaviour on
// a single input piece:
//   1. Substitute every ' ' with `replacement` (UTF-8 string, default "▁").
//   2. If prepend_scheme is Always or First, ensure the result starts with
//      `replacement`. Our PreTokenizer interface only ever sees one piece per
//      call, so "First" is collapsed into "Always" — correct for standalone
//      usage and for Metaspace as the leading pre-tokenizer in a Sequence.
//   3. If `split` is true, split on the leading-replacement boundary using
//      MergedWithNext semantics (every occurrence of `replacement` starts a
//      new piece).

MetaspacePreTokenizer::PrependScheme
MetaspacePreTokenizer::parse_prepend_scheme(const std::string &s) {
  if (s == "never" || s == "Never") {
    return PrependScheme::Never;
  }
  if (s == "first" || s == "First") {
    return PrependScheme::First;
  }
  if (s == "always" || s == "Always") {
    return PrependScheme::Always;
  }
  throw std::runtime_error("Unsupported Metaspace prepend_scheme: " + s +
                           " (expected never|first|always)");
}

std::vector<std::string>
MetaspacePreTokenizer::pre_tokenize(const std::string &input) const {
  if (input.empty()) {
    return {};
  }

  // Step 1: replace ' ' with replacement_.
  std::string substituted;
  substituted.reserve(input.size());
  for (char c : input) {
    if (c == ' ') {
      substituted += replacement_;
    } else {
      substituted += c;
    }
  }

  // Step 2: prepend if scheme says so.
  const bool should_prepend = prepend_scheme_ != PrependScheme::Never;
  if (should_prepend) {
    if (substituted.compare(0, replacement_.size(), replacement_) != 0) {
      substituted = replacement_ + substituted;
    }
  }

  if (!split_) {
    return {substituted};
  }

  // Step 3: split on `replacement_` with MergedWithNext semantics. Each
  // occurrence of replacement_ marks the start of a new piece.
  std::vector<std::string> pieces;
  size_t pos = 0;
  while (pos < substituted.size()) {
    size_t next = substituted.find(replacement_, pos + 1);
    if (next == std::string::npos) {
      pieces.push_back(substituted.substr(pos));
      break;
    }
    pieces.push_back(substituted.substr(pos, next - pos));
    pos = next;
  }

  return pieces;
}

} // namespace tokenizers
