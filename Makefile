include Makefile.config
export PATH := deps/aptos-core/target/release/:$(PATH)

.PHONY: build install-aptos test compile local-node

install-aptos:
	cd deps/aptos-core && cargo install --profile release --path crates/aptos

clean:
	rm -rf layerzero/build && rm -rf apps/bridge/build && rm -rf apps/oracle/build

clean-common:
	rm -rf layerzero-common/build

build:
	cd deps/aptos-core && cargo build --profile release

test-common:
	cd layerzero-common && aptos move test --named-addresses layerzero_common=${layerzero_common}

test-layerzero:
	cd layerzero && aptos move test --named-addresses layerzero_common=${layerzero_common},msglib_auth=${msglib_auth},zro=${zro},msglib_v1_1=${msglib_v1_1},msglib_v2=${msglib_v2},layerzero=${layerzero},executor_auth=${executor_auth},executor_v2=${executor_v2}

test-oracle:
	cd apps/oracle && aptos move test --named-addresses layerzero_common=${layerzero_common},msglib_auth=${msglib_auth},zro=${zro},msglib_v1_1=${msglib_v1_1},msglib_v2=${msglib_v2},executor_auth=${executor_auth},executor_v2=${executor_v2},layerzero=${layerzero},oracle=0xBEAD

test-bridge:
	cd apps/bridge && aptos move test --named-addresses layerzero_common=${layerzero_common},msglib_auth=${msglib_auth},zro=${zro},msglib_v1_1=${msglib_v1_1},msglib_v2=${msglib_v2},executor_auth=${executor_auth},executor_v2=${executor_v2},layerzero=${layerzero},bridge=0xBEAD


test: test-common test-layerzero test-oracle test-counter test-bridge

compile-common:
	cd layerzero-common && aptos move compile --included-artifacts=${included_artifacts} --save-metadata --named-addresses layerzero_common=${layerzero_common}

compile-zro:
	cd zro && aptos move compile --included-artifacts=${included_artifacts} --save-metadata --named-addresses zro=${zro}

compile-msglib-auth:
	cd ./msglib/msglib-auth && aptos move compile --included-artifacts=${included_artifacts} --save-metadata --named-addresses layerzero_common=${layerzero_common},msglib_auth=${msglib_auth}

compile-msglib-v2:
	cd ./msglib/msglib-v2 && aptos move compile --included-artifacts=${included_artifacts} --save-metadata --named-addresses layerzero_common=${layerzero_common},msglib_auth=${msglib_auth},zro=${zro},msglib_v2=${msglib_v2}

compile-msglib-v1-1:
	cd ./msglib/msglib-v1/msglib-v1-1 && aptos move compile --included-artifacts=${included_artifacts} --save-metadata --named-addresses layerzero_common=${layerzero_common},msglib_auth=${msglib_auth},zro=${zro},msglib_v1_1=${msglib_v1_1}

compile-layerzero:
	cd layerzero && aptos move compile --included-artifacts=${included_artifacts} --save-metadata --named-addresses layerzero_common=${layerzero_common},msglib_auth=${msglib_auth},zro=${zro},msglib_v1_1=${msglib_v1_1},msglib_v2=${msglib_v2},layerzero=${layerzero},executor_auth=${executor_auth},executor_v2=${executor_v2}

compile-executor-auth:
	cd ./executor/executor-auth && aptos move compile --included-artifacts=${included_artifacts} --save-metadata --named-addresses layerzero_common=${layerzero_common},executor_auth=${executor_auth}

compile-executor-v2:
	cd ./executor/executor-v2 && aptos move compile --included-artifacts=${included_artifacts} --save-metadata --named-addresses layerzero_common=${layerzero_common},executor_auth=${executor_auth},executor_v2=${executor_v2}

compile-oracle:
	cd apps/oracle && aptos move compile --included-artifacts=${included_artifacts} --save-metadata --named-addresses layerzero_common=${layerzero_common},msglib_auth=${msglib_auth},zro=${zro},msglib_v1_1=${msglib_v1_1},msglib_v2=${msglib_v2},executor_auth=${executor_auth},executor_v2=${executor_v2},layerzero=${layerzero},oracle=0xBEAD

compile-bridge:
	cd apps/bridge && aptos move compile --included-artifacts=${included_artifacts} --save-metadata --named-addresses layerzero_common=${layerzero_common},msglib_auth=${msglib_auth},zro=${zro},msglib_v1_1=${msglib_v1_1},msglib_v2=${msglib_v2},executor_auth=${executor_auth},executor_v2=${executor_v2},layerzero=${layerzero},bridge=0xBEAD

compile: compile-common compile-msglib-auth compile-zro compile-msglib-v1-1 compile-msglib-v2 compile-layerzero compile-counter compile-bridge compile-oracle compile-executor-v2 compile-executor-auth

publish-layerzero-common: 
	cd layerzero-common && aptos move publish --named-addresses layerzero_common=${layerzero_common}

publish-msglib-auth: 
	cd msglib/msglib-auth && aptos move publish --named-addresses msglib_auth=${msglib_auth},layerzero_common=${layerzero_common}

publish-zro:
	cd zro/ && aptos move publish --named-addresses zro=${zro} --assume-yes

publish-msglib-v1-1: 
	cd msglib/msglib-v1/msglib-v1-1 && aptos move publish --named-addresses msglib_v1_1=${msglib_v1_1},zro=${zro},layerzero_common=${layerzero_common},msglib_auth=${msglib_auth} --assume-yes

publish-msglib-v2: 
	cd msglib/msglib-v2 && aptos move publish --named-addresses msglib_v2=${msglib_v2},zro=${zro},layerzero_common=${layerzero_common},msglib_auth=${msglib_auth} --assume-yes

publish-executor-auth: 
	cd executor/executor-auth && aptos move publish --named-addresses layerzero_common=${layerzero_common},executor_auth=${executor_auth} --assume-yes

publish-executor-v2: 
	cd executor/executor-v2 && aptos move publish --named-addresses layerzero_common=${layerzero_common},executor_auth=${executor_auth},executor_v2=${executor_v2} --assume-yes

publish-layerzero:
	cd layerzero && aptos move publish --included-artifacts=${included_artifacts} --named-addresses layerzero_common=${layerzero_common},msglib_auth=${msglib_auth},zro=${zro},msglib_v1_1=${msglib_v1_1},msglib_v2=${msglib_v2},executor_auth=${executor_auth},executor_v2=${executor_v2},layerzero=${layerzero} --assume-yes

publish-bridge: 
	cd apps/bridge && aptos move publish --included-artifacts=${included_artifacts} --named-addresses layerzero_common=${layerzero_common},msglib_auth=${msglib_auth},zro=${zro},msglib_v1_1=${msglib_v1_1},msglib_v2=${msglib_v2},executor_auth=${executor_auth},executor_v2=${executor_v2},layerzero=${layerzero},bridge=${bridge} --assume-yes

publish: 
	publish-msglib-auth publish-zro publish-msglib-v1-1 publish-msglib-v2 publish-executor-auth publish-executor-v2 publish-layerzero

publish-counter: 
	cd apps/counter && aptos move publish --included-artifacts=${included_artifacts} --named-addresses layerzero_common=${layerzero_common},msglib_auth=${msglib_auth},zro=${zro},msglib_v1_1=${msglib_v1_1},msglib_v2=${msglib_v2},executor_auth=${executor_auth},executor_v2=${executor_v2},layerzero=${layerzero},counter=${counter}


local-node:
	@-pkill -f aptos
	rm -rf .aptos
	aptos node run-local-testnet --with-faucet &
	@curl --silent --retry 15 --retry-delay 2 --retry-connrefused http://localhost:8080/
	@curl --silent --retry 15 --retry-delay 2 --retry-connrefused http://localhost:8081/
