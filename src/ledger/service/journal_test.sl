fn test_exchange_sell_reservations_form_one_valid_posting_batch() {
    let account="00000000-0000-4000-a000-000000000011";
    let season="00000000-0000-4000-a000-000000000901";
    let market="00000000-0000-4000-a000-000000000900";
    let order="00000000-0000-4000-a000-000000000001";
    let batch=journal_batch();
    journal_reserve(batch,"user",account,season,"SEDI",1,order,"hold:"+order+":sedi");
    journal_reserve(batch,"user",account,season,"YES:"+market,8,order,"hold:"+order+":shares");
    assert(len(batch.transactions)==2);
    if let error=journal_problem(batch) { panic(error); }
    assert(batch.transactions[0].holds[0].amount==1 && batch.transactions[1].holds[0].amount==8);
    assert(batch.transactions[0].ref_id==order && batch.transactions[1].ref_id==order);
}

fn test_journal_bridge_preserves_hold_consumption_and_balancing() {
    let batch=journal_batch(); let rows=journal_rows();
    let account="00000000-0000-4000-a000-000000000011";
    let hold="00000000-0000-4000-a000-000000000012";
    let order="00000000-0000-4000-a000-000000000001";
    journal_entry(rows,"user",account,"SEDI","held",-1,hold);
    journal_entry(rows,"system","system:fees","SEDI","free",1,"");
    journal_hold(rows,"consume",hold,"user",account,"SEDI",1);
    journal_append(batch,rows,"fee:"+order,"FEE","00000000-0000-4000-a000-000000000901","00000000-0000-4000-a000-000000000900","order",order);
    if let error=journal_problem(batch) { panic(error); }
    assert(len(batch.transactions)==1 && batch.transactions[0].business_key=="fee:"+order);
}
