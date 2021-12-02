#set -e

for run in {1..100}; do
  yarn test test/Fuzzing.ts
done
