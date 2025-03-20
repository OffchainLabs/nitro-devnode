#!/bin/bash

NITRO_NODE_VERSION="v3.5.3-0a9c975"  # <-- only update this when you need a new version
TARGET_IMAGE="offchainlabs/nitro-node:${NITRO_NODE_VERSION}"
# By default, use nitro docker image. If "--stylus" is passed, build the image with stylus dev dependencies
STYLUS_MODE="false"

# Parse arguments
while [[ $# -gt 0 ]]; do
  case "$1" in
    --stylus)
      STYLUS_MODE="true"
      shift
      ;;
    *)
      echo "Unknown option: $1"
      exit 1
      ;;
  esac
done

if [[ "$STYLUS_MODE" == "true" ]]; then
  echo "Building Nitro node with Stylus dev dependencies..."
  # Build using the specific version
  docker build . --target nitro-node-stylus-dev \
  --tag nitro-node-stylus-dev  -f stylus-dev/Dockerfile \
  --build-arg NITRO_NODE_VERSION="${NITRO_NODE_VERSION}"

  TARGET_IMAGE="nitro-node-stylus-dev"
fi

# Check whether contracts submodule was initialized
if [[ ! -d "./contracts/src" ]]; then
  echo "Error: Contracts submodule not found. Initialize it with the following command:"
  echo "git submodule update --init --recursive"
  exit 1
fi

# Prepare nitro args.
NITRO_ARGS=(
  --dev
  --http.addr "0.0.0.0"
  --http.api "net,web3,eth,debug"
)

if [[ "${NITRO_DEV_ACCOUNT:-}" != "" ]]; then
  NITRO_ARGS+=(
    --init.dev-init-address "$NITRO_DEV_ACCOUNT"
  )
fi

# Start Nitro dev node in the background
echo "Starting Nitro dev node..."
docker run --rm --name nitro-dev -p 8547:8547 "${TARGET_IMAGE}" "${NITRO_ARGS[@]}" &

# Wait for the node to initialize
echo "Waiting for the Nitro node to initialize..."

until [[ "$(curl -s -X POST -H "Content-Type: application/json" \
  --data '{"jsonrpc":"2.0","method":"net_version","params":[],"id":1}' \
  http://127.0.0.1:8547)" == *"result"* ]]; do
    sleep 0.1
done


# Check if node is running
curl_output=$(curl -s -X POST -H "Content-Type: application/json" \
  --data '{"jsonrpc":"2.0","method":"net_version","params":[],"id":1}' \
  http://127.0.0.1:8547)

if [[ "$curl_output" == *"result"* ]]; then
  echo "Nitro node is running!"
else
  echo "Failed to start Nitro node."
  exit 1
fi

NITRO_DEV_PRIVATE_KEY="${NITRO_DEV_PRIVATE_KEY:-"0xb6b15c8cb491557369f3c7d2c287b053eb229daa9c22138887752191c9520659"}"

# Make the caller a chain owner
echo "Setting chain owner to pre-funded dev account..."
cast send 0x00000000000000000000000000000000000000FF "becomeChainOwner()" \
  --private-key "$NITRO_DEV_PRIVATE_KEY" \
  --rpc-url http://127.0.0.1:8547

# Deploy Cache Manager Contract
echo "Deploying Cache Manager contract..."
deploy_output=$(cast send --private-key "$NITRO_DEV_PRIVATE_KEY" \
  --rpc-url http://127.0.0.1:8547 \
  --create 0x60a06040523060805234801561001457600080fd5b50608051611d1c61003060003960006105260152611d1c6000f3fe)

# Extract contract address using awk from plain text output
contract_address=$(echo "$deploy_output" | awk '/contractAddress/ {print $2}')

# Check if contract deployment was successful
if [[ -z "$contract_address" ]]; then
  echo "Error: Failed to extract contract address. Full output:"
  echo "$deploy_output"
  exit 1
fi

echo "Cache Manager contract deployed at address: $contract_address"

# Register the deployed Cache Manager contract
echo "Registering Cache Manager contract as a WASM cache manager..."
registration_output=$(cast send --private-key "$NITRO_DEV_PRIVATE_KEY" \
  --rpc-url http://127.0.0.1:8547 \
  0x0000000000000000000000000000000000000070 \
  "addWasmCacheManager(address)" "$contract_address")

# Check if registration was successful
if [[ "$registration_output" == *"error"* ]]; then
  echo "Failed to register Cache Manager contract. Registration output:"
  echo "$registration_output"
  exit 1
fi
echo "Cache Manager deployed and registered successfully"

# Deploy StylusDeployer
deployer_output=$(forge create --private-key "$NITRO_DEV_PRIVATE_KEY" \
    --out ./contracts/out  --cache-path ./contracts/cache -r http://127.0.0.1:8547 \
    ./contracts/src/stylus/StylusDeployer.sol:StylusDeployer)
deployer_address=$(echo "$deployer_output" | awk '/Deployed to/ {print $3}')
if [[ -z "$deployer_address" ]]; then
  echo "Error: Failed to deploy StylusDeployer contract. Full output:"
  echo "$deployer_output"
  exit 1
fi
echo "StylusDeployer deployed at address: $deployer_address"

# If no errors, print success message
echo "Nitro node is running..."
wait  # Keep the script alive and the node running
