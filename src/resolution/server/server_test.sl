import "strings";

fn test_dto_structures() {
    let prop_dto = ProposeDto {
        outcome: "YES",
        reason: "Match finished 2-1",
        evidence_ids: ["ev-1", "ev-2"],
        version: 1
    };
    assert(prop_dto.outcome == "YES");
    assert(len(prop_dto.evidence_ids) == 2);
    assert(prop_dto.version == 1);

    let hold_dto = HoldDto {
        reason: "Under review due to dispute",
        version: 2
    };
    assert(hold_dto.version == 2);

    let decide_dto = DecideDisputeDto {
        decision: "ACCEPT",
        note: "Accepted after video review"
    };
    assert(decide_dto.decision == "ACCEPT");

    let fin_dto = FinalizeDto {
        outcome: "YES",
        void_reason: none,
        reason: "Final result confirmed",
        version: 3
    };
    assert(fin_dto.outcome == "YES");

    let disp_dto = CreateDisputeDto {
        reason: "Referee awarded disputed penalty at 90 min",
        link_url: some("https://video.example.com/replay")
    };
    assert(len(disp_dto.reason) > 20);
}
