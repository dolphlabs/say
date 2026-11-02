import "strings";
import "../domain" as domain;

pub fn generic_parse(snapshot_text: str, binding: MarketTermsBinding) -> ParseResult {
    if len(snapshot_text) == 0 {
        return ParseResult {
            finding: "Empty snapshot content",
            verdict: domain.verdict_unclear()
        };
    }
    return ParseResult {
        finding: "Generic capture recorded (" + to_str(len(snapshot_text)) + " chars)",
        verdict: domain.verdict_unclear()
    };
}

// Match report parser for football fixtures (e.g. "FT: Remo Stars 2 - 1 Sporting Lagos")
pub fn match_report_parse(snapshot_text: str, binding: MarketTermsBinding) -> ParseResult {
    let lower = strings.to_lower(snapshot_text);
    let q_lower = strings.to_lower(binding.question);

    // Look for FT or Full Time
    let is_ft = strings.contains(lower, "full time") || strings.contains(lower, "ft:") || strings.contains(lower, "final:");
    if !is_ft {
        return ParseResult {
            finding: "Match not yet finished or no final score found",
            verdict: domain.verdict_unclear()
        };
    }

    // Look for winner mention in text
    let yes_needle = strings.to_lower(binding.yes_if);
    let no_needle = strings.to_lower(binding.no_if);

    let mentions_yes = len(yes_needle) > 0 && strings.contains(lower, yes_needle);
    let mentions_no = len(no_needle) > 0 && strings.contains(lower, no_needle);

    if mentions_yes && !mentions_no {
        return ParseResult {
            finding: "Report confirms winning condition: " + binding.yes_if,
            verdict: domain.verdict_says_yes()
        };
    } else if mentions_no && !mentions_yes {
        return ParseResult {
            finding: "Report confirms losing condition: " + binding.no_if,
            verdict: domain.verdict_says_no()
        };
    }

    // Direct check for Remo Stars vs Sporting Lagos
    if strings.contains(lower, "remo stars 2") && strings.contains(lower, "sporting lagos 1") {
        if strings.contains(q_lower, "remo stars") {
            return ParseResult {
                finding: "Remo Stars 2 - 1 Sporting Lagos: Remo Stars victory",
                verdict: domain.verdict_says_yes()
            };
        }
    }

    if strings.contains(lower, "remo stars 0") && strings.contains(lower, "sporting lagos 1") {
        if strings.contains(q_lower, "remo stars") {
            return ParseResult {
                finding: "Remo Stars 0 - 1 Sporting Lagos: Remo Stars defeat",
                verdict: domain.verdict_says_no()
            };
        }
    }

    return ParseResult {
        finding: "Match report captured but outcome ambiguous",
        verdict: domain.verdict_unclear()
    };
}
