import "encoding";
import "strings";

pub gc struct RenderedNotice {
    title: str,
    body: str,
    link_url: str
}

pub fn fmt_ordinal(ord: int) -> str {
    if ord < 10 {
        return "0" + to_str(ord);
    }
    return to_str(ord);
}

pub fn order_filled_template(
    market_question: str,
    outcome: str,
    filled_qty: int,
    total_qty: int,
    price: int,
    is_final: bool
) -> RenderedNotice {
    let title = "Order filled";
    let body = to_str(total_qty) + " " + market_question + " " + outcome + " @ S " + to_str(price) + ".";
    if !is_final && filled_qty < total_qty {
        title = "Order partly filled";
        body = to_str(filled_qty) + " of " + to_str(total_qty) + " " + market_question + " " + outcome + " @ S " + to_str(price) + ". The rest is still waiting.";
    }
    return RenderedNotice {
        title: title,
        body: body,
        link_url: "/portfolio"
    };
}

pub fn order_cancelled_system_template(
    market_question: str,
    refund_sedi: int
) -> RenderedNotice {
    return RenderedNotice {
        title: "Order cancelled",
        body: market_question + " closed before your order filled. S " + to_str(refund_sedi) + " is back in your balance.",
        link_url: "/portfolio"
    };
}

pub fn closing_soon_template(
    market_question: str,
    close_time_wat: str
) -> RenderedNotice {
    return RenderedNotice {
        title: "Market closing soon",
        body: market_question + " closes at " + close_time_wat + ".",
        link_url: "/portfolio"
    };
}

pub fn result_proposed_template(
    market_question: str,
    proposed_outcome: str,
    dispute_mins: int
) -> RenderedNotice {
    return RenderedNotice {
        title: "Result proposed",
        body: market_question + ": " + proposed_outcome + ". It's final in " + to_str(dispute_mins) + " minutes unless disputed.",
        link_url: "/portfolio"
    };
}

pub fn market_settled_template(
    market_question: str,
    won: bool,
    winner_name: str,
    paid_out: int,
    pnl: int
) -> RenderedNotice {
    if won {
        let pnl_str = "+" + to_str(pnl);
        return RenderedNotice {
            title: "You called it",
            body: winner_name + " won. S " + to_str(paid_out) + " paid out (" + pnl_str + ").",
            link_url: "/portfolio"
        };
    }
    let pnl_abs = pnl;
    if pnl_abs < 0 { pnl_abs = -pnl_abs; }
    return RenderedNotice {
        title: "Not this time",
        body: market_question + " went the other way (−S " + to_str(pnl_abs) + ").",
        link_url: "/portfolio"
    };
}

pub fn season_started_template(
    ordinal: int,
    grant_amount: int
) -> RenderedNotice {
    return RenderedNotice {
        title: "Season " + fmt_ordinal(ordinal) + " is live",
        body: "S " + to_str(grant_amount) + " added. Go make some calls.",
        link_url: "/portfolio"
    };
}

pub fn season_final_template(
    ordinal: int,
    rank_pos: int,
    rank_of: int,
    season_pnl: int
) -> RenderedNotice {
    let pnl_str = to_str(season_pnl);
    if season_pnl >= 0 {
        pnl_str = "+" + to_str(season_pnl);
    }
    return RenderedNotice {
        title: "Season " + fmt_ordinal(ordinal) + " is final",
        body: "You finished #" + to_str(rank_pos) + " of " + to_str(rank_of) + " (" + pnl_str + ").",
        link_url: "/portfolio"
    };
}

pub fn default_notification_prefs() -> [NotificationPref] {
    return [
        NotificationPref {
            kind: "order_filled",
            label: "Order filled",
            hint: "When an order fills or partially fills",
            in_app: true,
            email: false
        },
        NotificationPref {
            kind: "order_cancelled_system",
            label: "Order cancelled by system",
            hint: "When an order is cancelled due to market close or self-trade",
            in_app: true,
            email: false
        },
        NotificationPref {
            kind: "closing_soon",
            label: "Closing soon",
            hint: "1 hour before a market you hold closes",
            in_app: true,
            email: false
        },
        NotificationPref {
            kind: "result_proposed",
            label: "Results proposed",
            hint: "When a proposed result is open for dispute",
            in_app: true,
            email: false
        },
        NotificationPref {
            kind: "market_settled",
            label: "Market settled",
            hint: "When a market settles and pays out",
            in_app: true,
            email: true
        },
        NotificationPref {
            kind: "season_started",
            label: "New season",
            hint: "When a new season starts and grants arrive",
            in_app: true,
            email: true
        },
        NotificationPref {
            kind: "season_final",
            label: "Season finalized",
            hint: "Final standings and season wrap-up",
            in_app: true,
            email: false
        },
        NotificationPref {
            kind: "weekly_recap",
            label: "Weekly recap",
            hint: "Sunday 18:00 WAT email summary of your week",
            in_app: false,
            email: false
        }
    ];
}
