pub enum GoogleOutcome {
    LogIn,
    Link,
    AlreadyLinked,
    LinkedElsewhere,
    StartSignup,
    EmailInUse,
    NeedSession
}

// What a verified Google identity leads to. The one place the linking
// policy lives: a Google email that matches an existing account is NOT
// linked automatically (GOOGLE_EMAIL_IN_USE); the owner logs in with the
// password and links Google from Settings, which proves both.
pub fn google_link_policy(intent: str, identity_owner: opt[str], email_owner: opt[str],
                          session_account: opt[str]) -> GoogleOutcome {
    if intent == "link" {
        guard let me = session_account else {
            return GoogleOutcome.NeedSession;
        }
        if let owner = identity_owner {
            if owner == me {
                return GoogleOutcome.AlreadyLinked;
            }
            return GoogleOutcome.LinkedElsewhere;
        }
        return GoogleOutcome.Link;
    }
    if let _owner = identity_owner {
        return GoogleOutcome.LogIn;
    }
    if let _taken = email_owner {
        return GoogleOutcome.EmailInUse;
    }
    return GoogleOutcome.StartSignup;
}

// An account must keep one way in: Google can go only if a password stays.
pub fn can_unlink_google(has_password: bool) -> bool {
    return has_password;
}
