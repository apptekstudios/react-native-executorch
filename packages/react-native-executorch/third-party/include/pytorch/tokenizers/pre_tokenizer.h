/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 * All rights reserved.
 *
 * This source code is licensed under the BSD-style license found in the
 * LICENSE file in the root directory of this source tree.
 */
// @lint-ignore-every LICENSELINT

#pragma once

// Standard
#include <memory>
#include <optional>
#include <string>
#include <vector>

// Third Party
#include <nlohmann/json.hpp>
#include <re2/re2.h>

// Local
#include <pytorch/tokenizers/regex.h>

namespace tokenizers {

// -- Base ---------------------------------------------------------------------

/**
 * Base class for all pre-tokenizers with a single virtual method to split the
 * input string piece
 */
class PreTokenizer {
public:
  /** Shared pointer type */
  typedef std::shared_ptr<PreTokenizer> Ptr;

  /** Split the input string piece into sub-pieces
   *
   * This pre-tokenization may result in sub-pieces that are not contained
   * within the original input, therefore the resulting pieces will be owned by
   * the caller.
   *
   * NOTE: Pass by value per best practice
   *  https://abseil.io/docs/cpp/guides/strings#string_view
   */
  virtual std::vector<std::string>
  pre_tokenize(const std::string &input) const = 0;

  virtual ~PreTokenizer() = default;
}; // end class PreTokenizer

// -- Factory ------------------------------------------------------------------

// Helper macro to standardize addition of config member fields
#define CONFIG_MEMBER(type, name)                                              \
  std::optional<type> name;                                                    \
  PreTokenizerConfig &set_##name(type arg) {                                   \
    this->name = std::move(arg);                                               \
    return *this;                                                              \
  }

/**
 * Factory and config class for creating a new PreTokenizer
 *
 * This class is the central method for instantiating a PreTokenizer instance.
 * It contains the common construction logic and config parameter names for all
 * pre tokenizer constructor args.
 *
 * NOTE: When adding a new pre tokenizer, you must ensure its arguments are
 *  added to this class and it's constructor is added in the implementation!
 *
 * Usage Example:
 *
 * const auto pre_tokenizer = PreTokenizerConfig("Sequence").set_pretokenizers(
 *   {PreTokenizerConfig("Digits"), PreTokenizerConfig("ByteLevel")}
 * );
 * const auto pre_tokenized = pre_tokenizer->pre_tokenize("Hello World!");
 */
class PreTokenizerConfig {
public:
  /*------------------------*/
  /* Public mutable members */
  /*------------------------*/

  /**
   * The Type name string matching from tokenizers
   * https://github.com/huggingface/tokenizers/blob/main/tokenizers/src/pre_tokenizers/mod.rs#L73
   */
  std::string type;

  /**
   * Used by: RegexPreTokenizer, ByteLevelPreTokenizer
   */
  CONFIG_MEMBER(std::string, pattern)

  /**
   * Used by: DigitsPreTokenizer
   */
  CONFIG_MEMBER(bool, individual_digits)

  /**
   * Used by: ByteLevelPreTokenizer
   */
  CONFIG_MEMBER(bool, add_prefix_space)

  /**
   * Used by RegexPreTokenizer
   */
  CONFIG_MEMBER(bool, is_delimiter)

  /**
   * Used by RegexPreTokenizer - Split behavior
   */
  CONFIG_MEMBER(std::string, behavior)

  /**
   * Used by RegexPreTokenizer - Split invert flag
   */
  CONFIG_MEMBER(bool, invert)

  /**
   * Used by: SequencePreTokenizer
   */
  CONFIG_MEMBER(std::vector<PreTokenizerConfig>, pretokenizers)

  /**
   * Used by: MetaspacePreTokenizer (UTF-8 string, default "▁" = U+2581)
   */
  CONFIG_MEMBER(std::string, replacement)

  /**
   * Used by: MetaspacePreTokenizer ("never" | "first" | "always")
   */
  CONFIG_MEMBER(std::string, prepend_scheme)

  /**
   * Used by: MetaspacePreTokenizer (whether to split on replacement)
   */
  CONFIG_MEMBER(bool, split)

  /*----------------*/
  /* Public methods */
  /*----------------*/

  /**
   * Construct with the type
   */
  explicit PreTokenizerConfig(std::string type = "");

  /**
   * Construct the pre tokenizer instance from the member data
   */
  PreTokenizer::Ptr create() const;

  /**
   * Populate from a json config file
   */
  PreTokenizerConfig &parse_json(const nlohmann::json &json_config);

}; // end class PreTokenizerConfig

// -- Regex --------------------------------------------------------------------
// Used for general-purpose single-regex pre tokenization
// CITE:
// https://github.com/huggingface/tokenizers/blob/main/tokenizers/src/pre_tokenizers/split.rs
//
// TODO: Support for "behavior" and "invert" options
//  https://github.com/huggingface/tokenizers/blob/main/tokenizers/src/tokenizer/normalizer.rs#L82
//  https://github.com/huggingface/tokenizers/blob/main/tokenizers/src/tokenizer/pattern.rs#L128

class RegexPreTokenizer : public PreTokenizer {
public:
  /**
   * @param pattern: The regex pattern to use for token splitting
   * @param is_delimiter: Whether treat `pattern` as delimiter characters, or
   * use `pattern` as a regex pattern.
   * @param behavior: Split behavior ("MergedWithPrevious" or "Isolated"
   * supported) For example: "pre_tokenizer": { "type": "Split", "pattern": {
   *     "String": " "
   *   },
   *   "behavior": "Isolated",
   *   "invert": false
   * },
   *
   * Behavior options:
   * - "MergedWithPrevious": Include delimiter with previous token
   *   Example: "the-final--countdown" -> ["the-", "final-", "-", "countdown"]
   * - "Isolated": Keep delimiters as separate tokens
   *   Example: "the-final--countdown" -> ["the", "-", "final", "-", "-",
   * "countdown"]
   *
   * Notice that the `invert` option is not supported.
   */
  explicit RegexPreTokenizer(const std::string &pattern,
                             bool is_delimiter = false,
                             const std::string &behavior = "Removed")
      : regex_(RegexPreTokenizer::create_regex_(pattern)),
        is_delimiter_(is_delimiter), behavior_(behavior) {
    if (behavior_.empty() ||
        (behavior_ != "Removed" && behavior_ != "MergedWithPrevious" &&
         behavior_ != "Isolated")) {
      throw std::runtime_error("Unsupported behavior: " + behavior_);
    }
  }

  /** Pre-tokenize with the stored regex */
  std::vector<std::string> pre_tokenize(const std::string &input) const;

protected:
  static std::unique_ptr<IRegex> create_regex_(const std::string &pattern);

  std::unique_ptr<IRegex> regex_;
  const bool is_delimiter_;
  const std::string behavior_;

}; // end class RegexPreTokenizer

// -- Digits -------------------------------------------------------------------
// Used by tokenizers
// CITE:
// https://github.com/huggingface/tokenizers/blob/main/tokenizers/src/pre_tokenizers/digits.rs

class DigitsPreTokenizer : public RegexPreTokenizer {
public:
  explicit DigitsPreTokenizer(bool individual_digits = false)
      : RegexPreTokenizer(individual_digits ? R"([^\p{N}]+|\p{N})"
                                            : R"([^\p{N}]+|[\p{N}]+)") {}
}; // end class DigitsPreTokenizer

// -- ByteLevel ----------------------------------------------------------------
// Used by tokenizers
// CITE:
// https://github.com/huggingface/tokenizers/blob/main/tokenizers/src/pre_tokenizers/byte_level.rs

class ByteLevelPreTokenizer : public PreTokenizer {
public:
  /**
   * @param add_prefix_space: Whether to add a leading space to the first word
   * @param pattern: A user-supplied regex to use for token splitting. If not
   *    provided, it use the standard GPT2 pattern.
   */
  ByteLevelPreTokenizer(bool add_prefix_space = true,
                        const std::string &pattern = "");
  explicit ByteLevelPreTokenizer(const std::string &pattern)
      : ByteLevelPreTokenizer(true, pattern) {}

  /** Perform pre-tokenization */
  std::vector<std::string>
  pre_tokenize(const std::string &input) const override;

private:
  const std::string pattern_;
  const bool add_prefix_space_;

}; // end class ByteLevelPreTokenizer

// -- Sequence -----------------------------------------------------------------
// Used by tokenizers
// CITE:
// https://github.com/huggingface/tokenizers/blob/main/tokenizers/src/pre_tokenizers/sequence.rs

class SequencePreTokenizer : public PreTokenizer {
public:
  /**
   * @param pre_tokenizers: The sequence of owned pre-tokenizer objects to use
   */
  explicit SequencePreTokenizer(std::vector<PreTokenizer::Ptr> pre_tokenizers);

  /** Perform pre-tokenization */
  std::vector<std::string>
  pre_tokenize(const std::string &input) const override;

private:
  const std::vector<PreTokenizer::Ptr> pre_tokenizers_;

}; // end class ByteLevelPreTokenizer

// -- BertPreTokenizer ---------------------------------------------------------
// Splits on whitespace (whitespace discarded) and then isolates each
// punctuation codepoint as its own token. Matches the HuggingFace Rust impl
// in huggingface/tokenizers/src/pre_tokenizers/bert.rs.

class BertPreTokenizer : public PreTokenizer {
public:
  BertPreTokenizer() = default;

  std::vector<std::string>
  pre_tokenize(const std::string &input) const override;
};

// -- Metaspace ----------------------------------------------------------------
// SentencePiece-style: replace each space in the input with a fixed
// `replacement` codepoint (default "▁" = U+2581), optionally prepend the
// replacement to the leading piece, then optionally split on the replacement.
// Matches huggingface/tokenizers/src/pre_tokenizers/metaspace.rs.

class MetaspacePreTokenizer : public PreTokenizer {
public:
  enum class PrependScheme { Never, First, Always };

  explicit MetaspacePreTokenizer(
      std::string replacement = "\xe2\x96\x81", // U+2581 in UTF-8
      PrependScheme prepend_scheme = PrependScheme::Always, bool split = true)
      : replacement_(std::move(replacement)), prepend_scheme_(prepend_scheme),
        split_(split) {}

  static PrependScheme parse_prepend_scheme(const std::string &s);

  std::vector<std::string>
  pre_tokenize(const std::string &input) const override;

private:
  const std::string replacement_;
  const PrependScheme prepend_scheme_;
  const bool split_;
};

} // namespace tokenizers
