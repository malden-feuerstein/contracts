#set -e

declare -i NUM_SUCCESSFUL=0
declare -i NUM_FAILED=0
for run in {1..1000}; do
    npx hardhat clean
    yarn test test/Fuzzing.ts
    if [ $? -eq 0 ]; then
        NUM_SUCCESSFUL=$((NUM_SUCCESSFUL + 1))
    else
        NUM_FAILED=$((NUM_FAILED + 1))
    fi
    echo "$((NUM_SUCCESSFUL))/$((NUM_FAILED + NUM_SUCCESSFUL)) have succeeded."
done
