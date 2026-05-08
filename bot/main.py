import os
import time
import logging
from web3 import Web3
from dotenv import load_dotenv

load_dotenv()

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s %(levelname)s %(message)s",
    datefmt="%Y-%m-%d %H:%M:%S",
)
log = logging.getLogger(__name__)

# --- Config ---
RPC_URL = os.getenv("BSC_RPC_URL")
PRIVATE_KEY = os.getenv("BOT_PRIVATE_KEY")
CONTRACT_ADDRESS = Web3.to_checksum_address(os.getenv("CONTRACT_ADDRESS"))
MIN_DUST_VALUE_BNB = 0.001  # skip tokens worth less than this in BNB
POLL_INTERVAL = 10          # seconds between scans

# PancakeSwap testnet router
ROUTER_ADDRESS = Web3.to_checksum_address("0xD99D1c33F9fC3444f8101754aBC46c52416550D1")

ROUTER_ABI = [
    {
        "inputs": [{"internalType": "uint256", "name": "amountIn", "type": "uint256"},
                   {"internalType": "address[]", "name": "path", "type": "address[]"}],
        "name": "getAmountsOut",
        "outputs": [{"internalType": "uint256[]", "name": "amounts", "type": "uint256[]"}],
        "stateMutability": "view",
        "type": "function",
    },
    {
        "inputs": [],
        "name": "WETH",
        "outputs": [{"internalType": "address", "name": "", "type": "address"}],
        "stateMutability": "pure",
        "type": "function",
    },
]

CONTRACT_ABI = [
    {
        "inputs": [
            {"internalType": "address", "name": "user", "type": "address"},
            {"internalType": "address[]", "name": "tokens", "type": "address[]"},
        ],
        "name": "sweep",
        "outputs": [],
        "stateMutability": "nonpayable",
        "type": "function",
    },
    {
        "inputs": [{"internalType": "address", "name": "", "type": "address"}],
        "name": "whitelistedTokens",
        "outputs": [{"internalType": "bool", "name": "", "type": "bool"}],
        "stateMutability": "view",
        "type": "function",
    },
]

ERC20_ABI = [
    {
        "inputs": [{"internalType": "address", "name": "owner", "type": "address"},
                   {"internalType": "address", "name": "spender", "type": "address"}],
        "name": "allowance",
        "outputs": [{"internalType": "uint256", "name": "", "type": "uint256"}],
        "stateMutability": "view",
        "type": "function",
    },
    {
        "inputs": [{"internalType": "address", "name": "account", "type": "address"}],
        "name": "balanceOf",
        "outputs": [{"internalType": "uint256", "name": "", "type": "uint256"}],
        "stateMutability": "view",
        "type": "function",
    },
    {
        "anonymous": False,
        "inputs": [
            {"indexed": True, "name": "owner", "type": "address"},
            {"indexed": True, "name": "spender", "type": "address"},
            {"indexed": False, "name": "value", "type": "uint256"},
        ],
        "name": "Approval",
        "type": "event",
    },
]


def main():
    w3 = Web3(Web3.HTTPProvider(RPC_URL))
    assert w3.is_connected(), "Cannot connect to RPC"

    bot_account = w3.eth.account.from_key(PRIVATE_KEY)
    log.info(f"Bot wallet: {bot_account.address}")
    log.info(f"Contract:   {CONTRACT_ADDRESS}")

    contract = w3.eth.contract(address=CONTRACT_ADDRESS, abi=CONTRACT_ABI)
    router = w3.eth.contract(address=ROUTER_ADDRESS, abi=ROUTER_ABI)
    wbnb = router.functions.WETH().call()

    # Track last scanned block to avoid re-processing
    last_block = w3.eth.block_number
    log.info(f"Starting from block {last_block}")

    # pending: {user -> set of token addresses} waiting to be swept
    pending: dict[str, set[str]] = {}

    while True:
        try:
            current_block = w3.eth.block_number

            if current_block > last_block:
                _scan_approvals(w3, last_block + 1, current_block, contract, pending)
                last_block = current_block

            if pending:
                _process_pending(w3, bot_account, contract, router, wbnb, pending)

        except Exception as e:
            log.error(f"Loop error: {e}")

        time.sleep(POLL_INTERVAL)


def _scan_approvals(w3, from_block, to_block, contract, pending):
    """Find new Approval events where spender == our contract."""
    log.info(f"Scanning blocks {from_block} → {to_block}")

    # Build a filter for Approval(owner, spender=CONTRACT_ADDRESS, value)
    approval_topic = Web3.keccak(text="Approval(address,address,uint256)").hex()
    spender_topic = "0x" + CONTRACT_ADDRESS[2:].lower().zfill(64)

    logs = w3.eth.get_logs({
        "fromBlock": from_block,
        "toBlock": to_block,
        "topics": [approval_topic, None, spender_topic],
    })

    for entry in logs:
        token = entry["address"]
        user = "0x" + entry["topics"][1].hex()[-40:]
        user = Web3.to_checksum_address(user)
        token = Web3.to_checksum_address(token)

        # Only process whitelisted tokens
        if not contract.functions.whitelistedTokens(token).call():
            continue

        log.info(f"Approval detected: user={user} token={token}")
        pending.setdefault(user, set()).add(token)


def _process_pending(w3, bot_account, contract, router, wbnb, pending):
    """For each pending user, check profitability and sweep if worthwhile."""
    gas_price = w3.eth.gas_price
    # Estimated gas for a sweep of one token
    estimated_gas = 200_000
    gas_cost_bnb = w3.from_wei(gas_price * estimated_gas, "ether")

    to_remove = []

    for user, tokens in list(pending.items()):
        profitable_tokens = []

        for token in list(tokens):
            token_contract = w3.eth.contract(
                address=Web3.to_checksum_address(token), abi=ERC20_ABI
            )
            allowance = token_contract.functions.allowance(
                user, CONTRACT_ADDRESS
            ).call()
            balance = token_contract.functions.balanceOf(user).call()
            amount = min(allowance, balance)

            if amount == 0:
                tokens.discard(token)
                continue

            # Check if dust value > gas cost
            try:
                amounts_out = router.functions.getAmountsOut(
                    amount, [Web3.to_checksum_address(token), wbnb]
                ).call()
                expected_bnb = w3.from_wei(amounts_out[1], "ether")
                fee_bnb = float(expected_bnb) * 0.15

                if fee_bnb > float(gas_cost_bnb):
                    profitable_tokens.append(Web3.to_checksum_address(token))
                    log.info(
                        f"Profitable: {token[:10]}… "
                        f"fee={fee_bnb:.6f} BNB > gas={gas_cost_bnb:.6f} BNB"
                    )
                else:
                    log.info(
                        f"Skipping (not profitable): {token[:10]}… "
                        f"fee={fee_bnb:.6f} BNB < gas={gas_cost_bnb:.6f} BNB"
                    )
            except Exception:
                log.warning(f"No liquidity for {token}, skipping")
                tokens.discard(token)

        if profitable_tokens:
            _execute_sweep(w3, bot_account, contract, user, profitable_tokens)
            for t in profitable_tokens:
                tokens.discard(t)

        if not tokens:
            to_remove.append(user)

    for user in to_remove:
        del pending[user]


def _execute_sweep(w3, bot_account, contract, user, tokens):
    log.info(f"Sweeping {len(tokens)} token(s) for {user}")
    try:
        nonce = w3.eth.get_transaction_count(bot_account.address)
        gas_price = w3.eth.gas_price

        tx = contract.functions.sweep(
            Web3.to_checksum_address(user), tokens
        ).build_transaction({
            "from": bot_account.address,
            "nonce": nonce,
            "gasPrice": gas_price,
            "gas": 300_000 * len(tokens),
        })

        signed = bot_account.sign_transaction(tx)
        tx_hash = w3.eth.send_raw_transaction(signed.raw_transaction)
        receipt = w3.eth.wait_for_transaction_receipt(tx_hash, timeout=60)

        if receipt["status"] == 1:
            log.info(f"✓ Sweep success: {tx_hash.hex()}")
        else:
            log.error(f"✗ Sweep failed: {tx_hash.hex()}")

    except Exception as e:
        log.error(f"Sweep error for {user}: {e}")


if __name__ == "__main__":
    main()
