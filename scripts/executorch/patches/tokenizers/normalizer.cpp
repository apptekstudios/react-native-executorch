/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 * All rights reserved.
 *
 * This source code is licensed under the BSD-style license found in the
 * LICENSE file in the root directory of this source tree.
 */
// @lint-ignore-every LICENSELINT

// Local
#include <pytorch/tokenizers/log.h>
#include <pytorch/tokenizers/normalizer.h>
#include <pytorch/tokenizers/regex.h>

// Third Party
#include <nlohmann/json.hpp>
#include <unicode.h>

// Standard
#include <algorithm>
#include <iterator>
#include <memory>
#include <string>
#include <utility>
#include <vector>

using json = nlohmann::json;

namespace tokenizers {

// NormalizerConfig ////////////////////////////////////////////////////////////

NormalizerConfig::NormalizerConfig(std::string type) : type(std::move(type)) {}

Normalizer::Ptr NormalizerConfig::create() const {
  // Type strings mirror the HuggingFace tokenizers Rust crate
  // (huggingface/tokenizers, src/normalizers/mod.rs).
  if (type == "Replace") {
    if (!pattern) {
      throw std::runtime_error(
          "Missing pattern for Normalizer of type Replace");
    }
    if (!content) {
      throw std::runtime_error(
          "Missing content for Normalizer of type Replace");
    }
    return Normalizer::Ptr(new ReplaceNormalizer(*pattern, *content));
  }
  if (type == "Prepend") {
    if (!prepend) {
      throw std::runtime_error(
          "Missing prepend for Normalizer of type Prepend");
    }
    return Normalizer::Ptr(new PrependNormalizer(*prepend));
  }
  if (type == "Sequence") {
    if (!normalizers || normalizers->empty()) {
      throw std::runtime_error(
          "Missing normalizers for Normalizer of type Sequence");
    }
    std::vector<Normalizer::Ptr> norms;
    std::transform(normalizers->begin(), normalizers->end(),
                   std::back_inserter(norms),
                   [](const NormalizerConfig &cfg) { return cfg.create(); });
    return Normalizer::Ptr(new SequenceNormalizer(std::move(norms)));
  }
  if (type == "NFC") {
    return Normalizer::Ptr(new NFCNormalizer());
  }
  if (type == "NFD") {
    return Normalizer::Ptr(new NFDNormalizer());
  }
  if (type == "NFKC") {
    return Normalizer::Ptr(new NFKCNormalizer());
  }
  if (type == "NFKD") {
    return Normalizer::Ptr(new NFKDNormalizer());
  }
  if (type == "Lowercase") {
    return Normalizer::Ptr(new LowercaseNormalizer());
  }
  if (type == "BertNormalizer") {
    return Normalizer::Ptr(new BertNormalizer(
        clean_text.value_or(true), handle_chinese_chars.value_or(true),
        lowercase.value_or(true), strip_accents));
  }
  if (type == "Strip") {
    return Normalizer::Ptr(new StripNormalizer(strip_left.value_or(true),
                                               strip_right.value_or(true)));
  }
  if (type == "StripAccents") {
    return Normalizer::Ptr(new StripAccentsNormalizer());
  }
  if (type == "Nmt") {
    return Normalizer::Ptr(new NmtNormalizer());
  }
  if (type == "ByteLevel") {
    return Normalizer::Ptr(new ByteLevelNormalizer());
  }
  if (type == "Precompiled") {
    if (!precompiled_charsmap) {
      throw std::runtime_error(
          "Missing precompiled_charsmap for Normalizer of type Precompiled");
    }
    return Normalizer::Ptr(new PrecompiledNormalizer(*precompiled_charsmap));
  }
  throw std::runtime_error("Unsupported Normalizer type: " + type);
}

NormalizerConfig &NormalizerConfig::parse_json(const json &json_config) {
  type = json_config.at("type");
  if (type == "Replace") {
    try {
      pattern = json_config.at("pattern").at("Regex");
    } catch (json::out_of_range &) {
      // "Regex" is not there, check "String", which is a literal string
      std::string literal = json_config.at("pattern").at("String");
      // For string patterns, escape regex special characters to treat them as
      // literal strings (same as Rust's regex::escape)
      pattern = IRegex::escape(literal);
    }
    content = json_config.at("content");
  } else if (type == "Prepend") {
    prepend = json_config.at("prepend");
  } else if (type == "Sequence") {
    normalizers = std::vector<NormalizerConfig>();
    for (const auto &entry : json_config.at("normalizers")) {
      normalizers->push_back(NormalizerConfig().parse_json(entry));
    }
  } else if (type == "BertNormalizer") {
    if (json_config.contains("clean_text")) {
      clean_text = json_config.at("clean_text").get<bool>();
    }
    if (json_config.contains("handle_chinese_chars")) {
      handle_chinese_chars = json_config.at("handle_chinese_chars").get<bool>();
    }
    if (json_config.contains("lowercase")) {
      lowercase = json_config.at("lowercase").get<bool>();
    }
    if (json_config.contains("strip_accents") &&
        !json_config.at("strip_accents").is_null()) {
      strip_accents = json_config.at("strip_accents").get<bool>();
    }
  } else if (type == "Strip") {
    if (json_config.contains("strip_left")) {
      strip_left = json_config.at("strip_left").get<bool>();
    }
    if (json_config.contains("strip_right")) {
      strip_right = json_config.at("strip_right").get<bool>();
    }
  } else if (type == "Precompiled") {
    precompiled_charsmap = json_config.at("precompiled_charsmap");
  } else if (type == "NFC" || type == "NFD" || type == "NFKC" ||
             type == "NFKD" || type == "Lowercase" || type == "StripAccents" ||
             type == "Nmt" || type == "ByteLevel") {
    // No additional configuration parameters for these.
    if (type == "NFKC" || type == "NFKD") {
      TK_LOG(Info,
             "Using %s normalizer with NFC/NFD approximation (compatibility "
             "decomposition tables not available).",
             type.c_str());
    }
  } else {
    throw std::runtime_error("Unsupported Normalizer type: " + type);
  }
  return *this;
}

// ReplaceNormalizer ///////////////////////////////////////////////////////////

std::unique_ptr<IRegex>
ReplaceNormalizer::create_regex_(const std::string &pattern) {
  assert(!pattern.empty());
  auto regex_result = create_regex(pattern);
  if (!regex_result.ok()) {
    std::string error =
        "Error: " + std::to_string(static_cast<int>(regex_result.error()));
    throw std::runtime_error(error);
  }
  return std::move(regex_result.get());
}

std::string ReplaceNormalizer::normalize(const std::string &input) const {
  if (!regex_) {
    return input;
  }

  std::string result = input;
  auto matches = regex_->find_all(result);

  // Process matches in reverse order to avoid offset issues
  for (auto it = matches.rbegin(); it != matches.rend(); ++it) {
    const auto &match = *it;
    result.replace(match.start, match.end - match.start, content_);
  }

  return result;
}

// PrependNormalizer ///////////////////////////////////////////////////////////

std::string PrependNormalizer::normalize(const std::string &input) const {
  if (input.empty()) {
    return "";
  }
  return prepend_ + input;
}

// SequenceNormalizer //////////////////////////////////////////////////////////

SequenceNormalizer::SequenceNormalizer(std::vector<Normalizer::Ptr> normalizers)
    : normalizers_(std::move(normalizers)) {}

std::string SequenceNormalizer::normalize(const std::string &input) const {
  std::string result = input;
  for (const auto &normalizer : normalizers_) {
    result = normalizer->normalize(result);
  }
  return result;
}

// Helpers /////////////////////////////////////////////////////////////////////

namespace {

std::string cpts_to_utf8(const std::vector<uint32_t> &cpts) {
  std::string result;
  result.reserve(cpts.size());
  for (uint32_t cp : cpts) {
    result += unicode_cpt_to_utf8(cp);
  }
  return result;
}

// HuggingFace tokenizers' Rust `is_chinese_char`
// (huggingface/tokenizers/src/normalizers/bert.rs).
bool is_chinese_char(uint32_t cp) {
  return (cp >= 0x4E00 && cp <= 0x9FFF) || (cp >= 0x3400 && cp <= 0x4DBF) ||
         (cp >= 0x20000 && cp <= 0x2A6DF) || (cp >= 0x2A700 && cp <= 0x2B73F) ||
         (cp >= 0x2B740 && cp <= 0x2B81F) || (cp >= 0x2B820 && cp <= 0x2CEAF) ||
         (cp >= 0xF900 && cp <= 0xFAFF) || (cp >= 0x2F800 && cp <= 0x2FA1F);
}

// Matches HF Rust `is_control`: exclude \t \n \r, otherwise Unicode control.
// Codepoint 0 is also explicitly handled (filtered by clean_text caller).
bool is_bert_control(uint32_t cp) {
  if (cp == '\t' || cp == '\n' || cp == '\r') {
    return false;
  }
  return unicode_cpt_flags(cp).is_control;
}

// Matches HF Rust `is_whitespace`: ASCII whitespace + Unicode whitespace.
bool is_bert_whitespace(uint32_t cp) {
  if (cp == ' ' || cp == '\t' || cp == '\n' || cp == '\r') {
    return true;
  }
  return unicode_cpt_flags(cp).is_whitespace;
}

} // namespace

// NFCNormalizer ///////////////////////////////////////////////////////////////

std::string NFCNormalizer::normalize(const std::string &input) const {
  auto cpts = unicode_cpts_from_utf8(input);
  auto normalized = unicode_cpts_normalize_nfc(cpts);
  return cpts_to_utf8(normalized);
}

// NFDNormalizer ///////////////////////////////////////////////////////////////

std::string NFDNormalizer::normalize(const std::string &input) const {
  auto cpts = unicode_cpts_from_utf8(input);
  auto normalized = unicode_cpts_normalize_nfd(cpts);
  return cpts_to_utf8(normalized);
}

// NFKCNormalizer //////////////////////////////////////////////////////////////
// Approximated with NFC; see header note.

std::string NFKCNormalizer::normalize(const std::string &input) const {
  auto cpts = unicode_cpts_from_utf8(input);
  auto normalized = unicode_cpts_normalize_nfc(cpts);
  return cpts_to_utf8(normalized);
}

// NFKDNormalizer //////////////////////////////////////////////////////////////
// Approximated with NFD; see header note.

std::string NFKDNormalizer::normalize(const std::string &input) const {
  auto cpts = unicode_cpts_from_utf8(input);
  auto normalized = unicode_cpts_normalize_nfd(cpts);
  return cpts_to_utf8(normalized);
}

// LowercaseNormalizer /////////////////////////////////////////////////////////

std::string LowercaseNormalizer::normalize(const std::string &input) const {
  auto cpts = unicode_cpts_from_utf8(input);
  for (auto &cp : cpts) {
    cp = unicode_tolower(cp);
  }
  return cpts_to_utf8(cpts);
}

// BertNormalizer //////////////////////////////////////////////////////////////
// Matches HF Rust order:
//   1. clean_text  (strip control chars, normalize whitespace to space)
//   2. handle_chinese_chars  (wrap CJK with spaces)
//   3. strip_accents (defaults to lowercase if unset): NFD then drop Mn
//   4. lowercase

std::string BertNormalizer::normalize(const std::string &input) const {
  auto cpts = unicode_cpts_from_utf8(input);

  if (clean_text_) {
    std::vector<uint32_t> cleaned;
    cleaned.reserve(cpts.size());
    for (uint32_t cp : cpts) {
      if (cp == 0 || cp == 0xFFFD || is_bert_control(cp)) {
        continue;
      }
      cleaned.push_back(is_bert_whitespace(cp) ? static_cast<uint32_t>(' ')
                                               : cp);
    }
    cpts = std::move(cleaned);
  }

  if (handle_chinese_chars_) {
    std::vector<uint32_t> wrapped;
    wrapped.reserve(cpts.size() * 2);
    for (uint32_t cp : cpts) {
      if (is_chinese_char(cp)) {
        wrapped.push_back(' ');
        wrapped.push_back(cp);
        wrapped.push_back(' ');
      } else {
        wrapped.push_back(cp);
      }
    }
    cpts = std::move(wrapped);
  }

  // strip_accents defaults to the value of lowercase when unset (HF parity).
  const bool do_strip_accents = strip_accents_.value_or(lowercase_);
  if (do_strip_accents) {
    auto decomposed = unicode_cpts_normalize_nfd(cpts);
    std::vector<uint32_t> stripped;
    stripped.reserve(decomposed.size());
    for (uint32_t cp : decomposed) {
      if (!unicode_cpt_flags(cp).is_accent_mark) {
        stripped.push_back(cp);
      }
    }
    cpts = std::move(stripped);
  }

  if (lowercase_) {
    for (auto &cp : cpts) {
      cp = unicode_tolower(cp);
    }
  }

  return cpts_to_utf8(cpts);
}

// StripNormalizer /////////////////////////////////////////////////////////////
// Trim leading/trailing whitespace codepoints.

std::string StripNormalizer::normalize(const std::string &input) const {
  if (input.empty()) {
    return input;
  }
  auto cpts = unicode_cpts_from_utf8(input);
  size_t lo = 0;
  size_t hi = cpts.size();
  if (strip_left_) {
    while (lo < hi && is_bert_whitespace(cpts[lo])) {
      ++lo;
    }
  }
  if (strip_right_) {
    while (hi > lo && is_bert_whitespace(cpts[hi - 1])) {
      --hi;
    }
  }
  std::vector<uint32_t> trimmed(cpts.begin() + lo, cpts.begin() + hi);
  return cpts_to_utf8(trimmed);
}

// StripAccentsNormalizer //////////////////////////////////////////////////////

std::string StripAccentsNormalizer::normalize(const std::string &input) const {
  auto cpts = unicode_cpts_from_utf8(input);
  auto decomposed = unicode_cpts_normalize_nfd(cpts);
  std::vector<uint32_t> stripped;
  stripped.reserve(decomposed.size());
  for (uint32_t cp : decomposed) {
    if (!unicode_cpt_flags(cp).is_accent_mark) {
      stripped.push_back(cp);
    }
  }
  return cpts_to_utf8(stripped);
}

// NmtNormalizer ///////////////////////////////////////////////////////////////
// Port of huggingface/tokenizers src/normalizers/utils.rs `Nmt`.
// Removes a fixed list of control codepoints and rewrites a fixed list of
// whitespace-like codepoints to ASCII space.

std::string NmtNormalizer::normalize(const std::string &input) const {
  auto cpts = unicode_cpts_from_utf8(input);
  std::vector<uint32_t> out;
  out.reserve(cpts.size());
  for (uint32_t cp : cpts) {
    // Filter list (HF Rust: '\x00'..='\x08' | '\x0B' | '\x0E'..='\x1F' |
    // '\x7F').
    if (cp <= 0x0008 || cp == 0x000B || (cp >= 0x000E && cp <= 0x001F) ||
        cp == 0x007F) {
      continue;
    }
    // Whitespace remap list.
    if (cp == 0x0009 || cp == 0x000A || cp == 0x000C || cp == 0x000D ||
        cp == 0x1680 || (cp >= 0x200B && cp <= 0x200F) || cp == 0x2028 ||
        cp == 0x2029 || cp == 0x2581 || cp == 0xFEFF || cp == 0xFFFD) {
      out.push_back(' ');
    } else {
      out.push_back(cp);
    }
  }
  return cpts_to_utf8(out);
}

// ByteLevelNormalizer /////////////////////////////////////////////////////////
// Map each input byte to its GPT-2-style visible UTF-8 character. See
// huggingface/tokenizers src/pre_tokenizers/byte_level.rs `bytes_char()`.

std::string ByteLevelNormalizer::normalize(const std::string &input) const {
  std::string result;
  result.reserve(input.size() * 2);
  for (unsigned char b : input) {
    result += unicode_byte_to_utf8(b);
  }
  return result;
}

// PrecompiledNormalizer ///////////////////////////////////////////////////////
// SentencePiece precompiled charsmap normalization (used by mBART / XLM-R /
// many Unigram SentencePiece models). We don't yet wire up the SentencePiece
// trie reader here, so the normalizer is a passthrough that logs once.
//
// TODO(rne): implement using sentencepiece::normalizer::Normalizer::
//   DecodePrecompiledCharsMap + a Darts trie lookup. Until then, models that
//   depend on the exact charsmap remap (e.g. mBART specific NFKC variants)
//   will see their inputs unchanged. Most BPE/HF tokenizer.json files do not
//   carry a Precompiled normalizer.

struct PrecompiledNormalizer::Impl {
  std::string charsmap;
};

PrecompiledNormalizer::PrecompiledNormalizer(
    const std::string &precompiled_charsmap)
    : impl_(std::make_unique<Impl>(Impl{precompiled_charsmap})) {
  TK_LOG(
      Info,
      "PrecompiledNormalizer is a passthrough in this build. Models that rely "
      "on SentencePiece precompiled charsmap normalization may see degraded "
      "tokenisation for inputs containing characters covered by the charsmap.");
}

PrecompiledNormalizer::~PrecompiledNormalizer() = default;

std::string PrecompiledNormalizer::normalize(const std::string &input) const {
  return input;
}

} // namespace tokenizers
