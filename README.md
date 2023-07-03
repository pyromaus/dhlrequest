# Tracking and Delay Insurance (TADI)

## DHL API Shipment Tracking via Chainlink Functions

This contract makes use of Chainlink Functions to get tracking data from the DHL API. The user (shipper) can store information about their shipments (shipping containers) and their respective tracking data. And the user can purchase delay protection which will earn them a payout in the event of a delay in their shipment's delivery. The user can buy delay protection to receive an instant payout if their shipment is late.

This repository has just a few files to show the critical components of the project. The entire file and codebase can be viewed upon request. 

TO DO:
1. Get access to Etherisc risk pools to allow the purchase of real delay protection.

### TADIEngine.sol

The Solidity smart contract that lives on-chain, stores shipping data and executes insurance claims. Based contract.

### DHLsource.js

The JavaScript source code that calls the DHL unified shipment tracking API. The Chainlink DON runs this script on 10 decentralised oracles and returns an aggregated response to us.

### DHLrequest.js

This script puts everything together and acts as a test for the smart contract. We produce an instance of the contract on the Polygon Mumbai chain and test its various capabilities. Then a Chainlink Functions request is built, we feed it the source code that calls the DHL API along with the arguments and encrypted API keys, and get a response that gets fed back to our contract.
