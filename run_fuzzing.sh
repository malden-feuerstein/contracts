#set -e

for run in {1..1000}; do
    npx hardhat clean
    yarn test test/Fuzzing.ts
done
