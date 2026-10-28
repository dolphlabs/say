import "../service" as exchange;

fn test_order_intent_requires_positive_bounded_limit_quantity() {
    let bad=exchange.Intent {
        account_id:"00000000-0000-4000-a000-000000000001",
        market_id:"00000000-0000-4000-a000-000000000002",
        request_type:"limit",outcome:"YES",side:"BUY",price:some(10),qty:some(0),tif:none,spend:none
    };
    let failure=exchange.intent_shape(bad);
    if let problem=failure {
        assert(problem.code=="QTY_TOO_LARGE");
    } else {
        panic("zero quantity passed request validation");
    }
}
