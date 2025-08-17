## Cài đặt

npm i
cp .env.example .env # điền PRIVATE_KEY, VRF_WRAPPER, ...
npm run build

## Chế độ 1: Somnia testnet (VRF thật)

# 1. Deploy + open round

npx hardhat run scripts/01-openRound.ts --network somnia

# -> copy CONTRACT_ADDRESS vào .env

# 2. Commit vé

NUMBERS=1,7,12,23,34,55 QTY=2 npx hardhat run scripts/02-commitBuy.ts --network somnia

# 3. Sau salesEnd -> Reveal

npx hardhat run scripts/03-reveal.ts --network somnia

# 4. Sau revealEnd -> Draw (VRF)

npx hardhat run scripts/04-requestDraw.ts --network somnia

# 5. Kiểm tra kết quả

npx hardhat run scripts/05-getWinning.ts --network somnia

# 6. Claim

npx hardhat run scripts/06-claim.ts --network somnia

## Chế độ 2: Local Hardhat (simulate VRF)

# Mở node cục bộ

npx hardhat node

# Mở console, deploy MockVRFWrapper + VietlotCommitReveal trỏ đến mock

# hoặc sửa 01-openRound.ts để deploy MockVRFWrapper trước:

# - deploy MockVRFWrapper

# - dùng địa chỉ mock làm VRF_WRAPPER

# Sau đó chạy commit/reveal như thường,

# cuối cùng gọi fulfill manual trên MockVRFWrapper:

# await mock.fulfill(<contractAddress>, <lastRequestId>, [123,456])
