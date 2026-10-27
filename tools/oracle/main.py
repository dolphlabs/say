import json
import sys

from exchange import Exchange


def main():
    exchange = None
    pending = None
    for line in sys.stdin:
        try:
            request = json.loads(line)
            op = request["op"]
            if op == "init":
                exchange = Exchange(request["policy"], request.get("pairs", 0))
                pending = None
            elif op == "restore":
                exchange = Exchange.from_snapshot(request["snapshot"])
                pending = None
            elif exchange is None:
                raise ValueError("NOT_INITIALIZED")
            elif op in ("step", "plan"):
                pending = exchange.plan(request["command"])
                if op == "step":
                    exchange.apply(pending)
            elif op == "apply":
                if pending is None:
                    raise ValueError("NO_PLAN")
                exchange.apply(pending)
            elif op == "discard":
                pending = None
            elif op == "replay":
                exchange = Exchange.from_snapshot(request["snapshot"])
                for transition in request["transitions"]:
                    exchange.apply_transition(transition)
                pending = None
            elif op not in ("snapshot", "verify"):
                raise ValueError("INVALID_OPERATION")
            exchange.verify()
            response = {"snapshot": exchange.snapshot(), "full_hash": exchange.full_hash()}
            if op in ("step", "plan"):
                response["transition"] = pending.transition
            print(json.dumps(response, sort_keys=True, separators=(",", ":")))
        except (ValueError, KeyError, TypeError) as error:
            print(json.dumps({"error": str(error)}, separators=(",", ":")))


if __name__ == "__main__":
    main()
