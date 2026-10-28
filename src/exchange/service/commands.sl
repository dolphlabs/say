import "json";
import "../domain" as core;

pub gc struct Queue[C] {
    store: CommandQueue[C]
}

pub fn new_queue[C](store: CommandQueue[C]) -> Queue[C] {
    return Queue[C] { store: store };
}

pub fn sync_lifecycle[C](queue: Queue[C], market_id: str) -> result[int,str] {
    if !valid_uuid(market_id) { return err("INVALID_COMMAND"); }
    return queue.store.sync_lifecycle(queue.store.context,market_id);
}

pub fn enqueue_control[C](queue: Queue[C], command: EnqueueCommand) -> result[EnqueueResult, str] {
    if !valid_uuid(command.market_id) || !valid_uuid(command.command_ref) ||
       len(command.source_key) < 1 || len(command.source_key) > 200 ||
       command.bucket_start < 0 || command.bucket_start > 15 {
        return err("INVALID_COMMAND");
    }
    if command.command_type != "CancelAll" && command.command_type != "Suspend" &&
       command.command_type != "Resume" && command.command_type != "Close" &&
       command.command_type != "Snapshot" {
        return err("INVALID_COMMAND");
    }
    if len(command.order_id) > 0 {
        return err("INVALID_COMMAND");
    }
    let write = queue.store.enqueue_control;
    return write(queue.store.context, command);
}

pub fn enqueue_cancel[C](queue: Queue[C], market_id: str, order_id: str, account_id: str,
                         command_ref: str, source_key: str) -> result[EnqueueResult, str] {
    if !valid_uuid(market_id) || !valid_uuid(order_id) || !valid_uuid(account_id) ||
       !valid_uuid(command_ref) || len(source_key)<1 || len(source_key)>200 {
        return err("INVALID_CANCEL");
    }
    let command=core.Command {
        kind:"Cancel",seq:0,ref:command_ref,order:core.empty_order(),order_id:order_id,
        account_id:account_id,system:false,reason:"USER_CANCEL"
    };
    let write=queue.store.enqueue_cancel;
    return write(queue.store.context,market_id,order_id,account_id,command_ref,source_key,json.encode(command));
}

pub fn enqueue_cancel_owned[C](queue: Queue[C], order_id: str, account_id: str,
                               command_ref: str) -> result[EnqueueResult, str] {
    if !valid_uuid(order_id) || !valid_uuid(account_id) || !valid_uuid(command_ref) {
        return err("INVALID_CANCEL");
    }
    let write=queue.store.enqueue_cancel_owned;
    return write(queue.store.context,order_id,account_id,command_ref);
}

pub fn load_pending[C](queue: Queue[C], market_id: str, after_command_id: int, limit: int) -> result[CommandBatch, str] {
    if !valid_uuid(market_id) || after_command_id < 0 || limit < 1 || limit > 64 {
        return err("INVALID_COMMAND_WINDOW");
    }
    let load = queue.store.load_pending;
    return load(queue.store.context, market_id, after_command_id, limit);
}
