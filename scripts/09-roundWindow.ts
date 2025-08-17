import { ethers } from "hardhat"

const ABI = [
  "event RoundOpened(uint256 indexed id, uint64 salesStart, uint64 salesEnd, uint64 revealEnd)",
]

function toISO(s: number) {
  return new Date(s * 1000).toISOString()
}
function hexToNum(h: string) {
  return Number(BigInt(h))
}

async function fetchLogsRaw(
  address: string,
  topic: string,
  from: number,
  to: number,
) {
  // eth_getLogs expects hex block numbers
  const toHex = (n: number) => "0x" + n.toString(16)
  const filter = {
    address,
    topics: [topic],
    fromBlock: toHex(from),
    toBlock: toHex(to),
  }
  // return raw logs array (no normalization, no "removed" needed)
  return await ethers.provider.send("eth_getLogs", [filter])
}

async function main() {
  const addr = process.env.CONTRACT_ADDRESS!
  if (!addr) throw new Error("Missing CONTRACT_ADDRESS")

  const iface = new ethers.Interface(ABI)
  const topic = iface.getEvent("RoundOpened").topicHash

  const latest = await ethers.provider.getBlockNumber()
  const CHUNK = Number(process.env.LOG_CHUNK_SIZE || 900) // < 1000
  const MAX_SCAN = Number(process.env.MAX_SCAN_BLOCKS || 200_000)
  const startHint = process.env.START_BLOCK
    ? Number(process.env.START_BLOCK)
    : 0

  let from = Math.max(startHint, latest - CHUNK)
  let to = latest
  let scanned = 0
  let found: {
    id: number
    salesStart: number
    salesEnd: number
    revealEnd: number
    blockNumber: number
  } | null = null

  while (to >= startHint && scanned <= MAX_SCAN) {
    const rawLogs = await fetchLogsRaw(addr, topic, from, to)

    if (rawLogs.length > 0) {
      const last = rawLogs[rawLogs.length - 1]
      const parsed = iface.parseLog({ data: last.data, topics: last.topics })
      found = {
        id: Number(parsed.args.id),
        salesStart: Number(parsed.args.salesStart),
        salesEnd: Number(parsed.args.salesEnd),
        revealEnd: Number(parsed.args.revealEnd),
        blockNumber: hexToNum(last.blockNumber),
      }
      break
    }

    scanned += to - from + 1
    to = from - 1
    from = Math.max(startHint, to - CHUNK)
  }

  if (!found) {
    console.log("Không tìm thấy RoundOpened trong phạm vi đã quét.")
    console.log(
      "→ Thử đặt START_BLOCK gần block deploy hoặc tăng MAX_SCAN_BLOCKS.",
    )
    return
  }

  const now = Math.floor(Date.now() / 1000)
  console.log("currentRoundId  :", found.id)
  console.log("lastEventBlock  :", found.blockNumber)
  console.log("now             :", now, toISO(now))
  console.log("salesStart      :", found.salesStart, toISO(found.salesStart))
  console.log("salesEnd        :", found.salesEnd, toISO(found.salesEnd))
  console.log("revealEnd       :", found.revealEnd, toISO(found.revealEnd))

  if (now < found.salesStart) {
    console.log("⏳ Round chưa mở bán.")
  } else if (now >= found.salesStart && now < found.salesEnd) {
    console.log("✅ ĐANG TRONG SALES WINDOW (commitBuy chạy được).")
  } else if (now >= found.salesEnd && now < found.revealEnd) {
    console.log(
      "ℹ️  Sales đã đóng, đang trong REVEAL WINDOW (commitBuy sẽ revert).",
    )
  } else {
    console.log(
      "⛔ Reveal đã hết. Gọi requestDraw rồi chờ VRF fulfill trước khi open round mới.",
    )
  }
}

main().catch((e) => {
  console.error(e)
  process.exit(1)
})
