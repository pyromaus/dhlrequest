const ethcrypto = require("eth-crypto")
const axios = require("axios")
const fs = require("fs").promises
const { ethers } = require("ethers")

async function main() {

  const provider = new ethers.providers.JsonRpcProvider(process.env.POLYGON_MUMBAI_RPC_URL)

  const signerPrivateKey = process.env.PRIVATE_KEY
  const signer = new ethers.Wallet(signerPrivateKey, provider)

  const tadiEngineAddress = "0x6266530eCC40E53d20Fd22C50fcF2a08DBD78B95"
  const tadiEngineAbiPath = "build/artifacts/contracts/TADIEngine.sol/TADIEngine.json"

  const contractAbi = JSON.parse(await fs.readFile(tadiEngineAbiPath, "utf8")).abi
  const tadiContract = new ethers.Contract(tadiEngineAddress, contractAbi, signer)

  const startingTadiBalance = await tadiContract.provider.getBalance(tadiContract.address)
  console.log(`Welcome to the Tracking and Delay Insurance (TADI) App`)
  console.log(`Starting TADI balance: ${startingTadiBalance}`)
  console.log(`Payout = 0.2 MATIC`)
  console.log(`Premium = 0.02 MATIC`)

  const newShipperAddy = "0x9b25b2a4675b0efe83c12365456cdc2f2e588fb7"
  const containerOrigin = "Honky Tonk Town"
  const grossWeight = 2500
  const trackingNumber = "00340434726200036723"
  const dueDate = 1688852486
  const parsedPremium = ethers.utils.parseEther("0.02")
  const newShipperTx = await tadiContract.newShipper(newShipperAddy)
  console.log("Creating new Shipper file..")
  const shipperTxResponse = await newShipperTx.wait(1)
  const newContainerTx = await tadiContract.addContainer(
    newShipperAddy,
    containerOrigin,
    grossWeight,
    trackingNumber,
    dueDate,
    { gasLimit: 12000000 }
  )
  console.log("Adding shipment container info...")
  const containerTxResponse = await newContainerTx.wait(1)
  const containerID = 1
  console.log(`New Container ID: ${containerID}`)
  const checkForDelayTx = await tadiContract.checkForDelay(containerID)
  const checkForDelayTxResponse = await checkForDelayTx.wait(2)
  const tadiBalance = await tadiContract.provider.getBalance(tadiContract.address)
  console.log(`Checked for delays. Contract balance: ${tadiBalance}`)

  console.log(`Purchasing delay protection for the container...`)

  const purchaseTx = await tadiContract.purchaseDelayProtection(containerID, {
    value: parsedPremium,
    gasLimit: 12000000,
  })
  const purchaseReceipt = await purchaseTx.wait(1)

  await tadiContract.simulateDelay(containerID)
  console.log(`Simulating delay... Container ${containerID} is due YESTERDAY`)

  const secondDelayTx = await tadiContract.checkForDelay(containerID, { gasLimit: 4200000 })
  console.log("Checking for shipment delays..")
  await secondDelayTx.wait(2)
  console.log(`Delay detected, with protection. Sending payout immediately..`)

  const tadiEndingBalance = await tadiContract.provider.getBalance(tadiContract.address)
  console.log(`TADI ending balance: ${tadiEndingBalance}`)
  console.log(`Payout = 0.2 MATIC`)
  console.log(`Premium = 0.02 MATIC`)

  console.log(`Attempting to track your container via the DHL API...`)
  // Transaction config
  const gasLimit = 12000000 // Transaction gas limit
  const verificationBlocks = 2 // Number of blocks to wait for transaction

  // Chainlink Functions request config
  // Chainlink Functions subscription ID
  const subscriptionId = 1305
  // Gas limit for the Chainlink Functions request
  const requestGas = 12000000

  const source = await fs.readFile("./DHLsource.js", "utf8")
  const args = [trackingNumber]
  const secrets = { dhlKey: process.env.DHLKEY }

  const oracleAddress = "0xeA6721aC65BCeD841B8ec3fc5fEdeA6141a0aDE4" // Polygon Mumbai
  const oracleAbiPath = "build/artifacts/contracts/dev/functions/FunctionsOracle.sol/FunctionsOracle.json"
  const oracleAbi = JSON.parse(await fs.readFile(oracleAbiPath, "utf8")).abi
  const oracle = new ethers.Contract(oracleAddress, oracleAbi, signer)

  let encryptedSecrets
  let doGistCleanup
  let gistUrl
  if (typeof secrets !== "undefined") {
    const result = await getEncryptedSecrets(secrets, oracle, signerPrivateKey)
    if (isObject(secrets)) {
      doGistCleanup = true
      encryptedSecrets = result.encrypted
      gistUrl = result.gistUrl
    } else {
      doGistCleanup = false
      encryptedSecrets = result
    }
  } else {
    encryptedSecrets = "0x"
  }

  let store = {}
  oracle.on("UserCallbackError", (eventRequestId, msg) => {
    store[eventRequestId] = { userCallbackError: true, msg: msg }
  })
  oracle.on("UserCallbackRawError", (eventRequestId, msg) => {
    store[eventRequestId] = { userCallbackRawError: true, msg: msg }
  })
  tadiContract.on("OCRResponse", (eventRequestId, response, err) => {
    store[eventRequestId] = { response: response, err: err }
  })

  await new Promise(async (resolve, reject) => {
    let cleanupInProgress = false
    const cleanup = async () => {
      if (doGistCleanup) {
        if (!cleanupInProgress) {
          cleanupInProgress = true
          await deleteGist(process.env["GITHUB_API_TOKEN"], gistUrl)
          return resolve()
        }
        return
      }
      return resolve()
    }

    const requestTx = await tadiContract.executeRequest(
      source,
      encryptedSecrets ?? "0x",
      args ?? [],
      subscriptionId,
      requestGas,
      { gasLimit: gasLimit }
    )

    let requestId

    console.log(`Waiting ${verificationBlocks} blocks for transaction ` + `${requestTx.hash} to be confirmed...`)

    const requestTxReceipt = await requestTx.wait(verificationBlocks)

    const requestEvent = requestTxReceipt.events.filter((event) => event.event === "RequestSent")[0]

    requestId = requestEvent.args.id
    console.log(`\nRequest ${requestId} initiated`)

    console.log(`Waiting for fulfillment...\n`)

    let polling
    async function checkStore() {
      const result = store[requestId]
      if (result) {
        console.log(`\nRequest ${requestId} fulfilled!`)
        if (result.userCallbackError) {
          console.error(
            "Error encountered when calling fulfillRequest in client contract.\n" +
              "Ensure the fulfillRequest function in the client contract is correct and the --gaslimit is sufficient."
          )
          console.error(`${msg}\n`)
        } else if (result.userCallbackRawError) {
          console.error("Raw error in contract request fulfillment. Please contact Chainlink support.")
          console.error(Buffer.from(msg, "hex").toString())
        } else {
          const { response, err } = result
          if (response !== "0x") {
            console.log(
              `Response returned to client contract represented as a hex string: ${BigInt(response).toString()}`
            )
          }
          if (err !== "0x") {
            console.error(`Error message returned to client contract: "${Buffer.from(err.slice(2), "hex")}"\n`)
          }
        }

        clearInterval(polling)
        await cleanup()
      }
    }

    polling = setInterval(checkStore, 1000)

    setTimeout(() => reject("5 minutes brah"), 300_000)
  })
  const testTx = await tadiContract.ltrTester("Holland", "1696969696", { gasLimit: 4200000 })
  await testTx.wait(1)
  const updaterTx = await tadiContract.trackingUpdater(containerID, { gasLimit: 4200000 })
  await updaterTx.wait(1)
  console.log(`Latest Location and timestamp:`)
  const latestLoc = await tadiContract.getLatestLocation(containerID)
  const latestTimestamp = await tadiContract.getLatestTimestamp(containerID)
  console.log(`Location: ${latestLoc}`)
  console.log(`Time: ${latestTimestamp}`)
}

// Encrypt the secrets as defined in requestConfig
// This is a modified version of buildRequest.js from the starter kit:
// ./FunctionsSandboxLibrary/buildRequest.js
// Expects one of the following:
//   - A JSON object with { apiKey: 'your_secret_here' }
//   - An array of secretsURLs
async function getEncryptedSecrets(secrets, oracle, signerPrivateKey = null) {
  let DONPublicKey = await oracle.getDONPublicKey()

  DONPublicKey = DONPublicKey.slice(2)

  if (isObject(secrets) && secrets) {
    if (!signerPrivateKey) {
      throw Error("signerPrivateKey is required to encrypt inline secrets")
    }

    const offchainSecrets = {}
    offchainSecrets["0x0"] = Buffer.from(
      await (0, encryptWithSignature)(signerPrivateKey, DONPublicKey, JSON.stringify(secrets)),
      "hex"
    ).toString("base64")

    if (!process.env["GITHUB_API_TOKEN"] || process.env["GITHUB_API_TOKEN"] === "") {
      throw Error("GITHUB_API_TOKEN environment variable not set")
    }

    const secretsURL = await createGist(process.env["GITHUB_API_TOKEN"], offchainSecrets)
    console.log(`Successfully created encrypted secrets Gist: ${secretsURL}`)
    return {
      gistUrl: secretsURL,
      encrypted: "0x" + (await (0, encrypt)(DONPublicKey, `${secretsURL}/raw`)),
    }
  }
  if (secrets.length > 0) {
    if (!Array.isArray(secrets)) {
      throw Error("Unsupported remote secrets format.  Remote secrets must be an array.")
    }

    if (await verifyOffchainSecrets(secrets, oracle)) {
      return "0x" + (await (0, encrypt)(DONPublicKey, secrets.join(" ")))
    } else {
      throw Error("Could not verify off-chain secrets.")
    }
  }

  return "0x"
}

// Check each URL in secretsURLs to make sure it is available
// Code is from ./tasks/Functions-client/buildRequestJSON.js
// in the starter kit.
async function verifyOffchainSecrets(secretsURLs, oracle) {
  const [nodeAddresses] = await oracle.getAllNodePublicKeys()
  const offchainSecretsResponses = []
  for (const url of secretsURLs) {
    try {
      const response = await axios.request({
        url,
        timeout: 3000,
        responseType: "json",
        maxContentLength: 1000000,
      })
      offchainSecretsResponses.push({
        url,
        secrets: response.data,
      })
    } catch (error) {
      throw Error(`Failed to fetch off-chain secrets from ${url}\n${error}`)
    }
  }

  for (const { secrets, url } of offchainSecretsResponses) {
    if (JSON.stringify(secrets) !== JSON.stringify(offchainSecretsResponses[0].secrets)) {
      throw Error(
        `Off-chain secrets URLs ${url} and ${offchainSecretsResponses[0].url} ` +
          `do not contain the same JSON object. All secrets URLs must have an ` +
          `identical JSON object.`
      )
    }

    for (const nodeAddress of nodeAddresses) {
      if (!secrets[nodeAddress.toLowerCase()]) {
        if (!secrets["0x0"]) {
          throw Error(`No secrets specified for node ${nodeAddress.toLowerCase()} and ` + `no default secrets found.`)
        }
      }
    }
  }
  return true
}

// Encrypt with the signer private key for sending secrets through an on-chain contract
// Code is from ./FunctionsSandboxLibrary/encryptSecrets.js
async function encryptWithSignature(signerPrivateKey, readerPublicKey, message) {
  const signature = ethcrypto.default.sign(signerPrivateKey, ethcrypto.default.hash.keccak256(message))
  const payload = {
    message,
    signature,
  }
  return await (0, encrypt)(readerPublicKey, JSON.stringify(payload))
}

// Encrypt with the DON public key
// Code is from ./FunctionsSandboxLibrary/encryptSecrets.js
async function encrypt(readerPublicKey, message) {
  const encrypted = await ethcrypto.default.encryptWithPublicKey(readerPublicKey, message)
  return ethcrypto.default.cipher.stringify(encrypted)
}

const createGist = async (githubApiToken, encryptedOffchainSecrets) => {
  await checkTokenGistScope(githubApiToken)

  const content = JSON.stringify(encryptedOffchainSecrets)

  const headers = {
    Authorization: `token ${githubApiToken}`,
  }

  const url = "https://api.github.com/gists"
  const body = {
    public: false,
    files: {
      [`encrypted-functions-request-data-${Date.now()}.json`]: {
        content,
      },
    },
  }

  try {
    const response = await axios.post(url, body, { headers })
    const gistUrl = response.data.html_url
    return gistUrl
  } catch (error) {
    console.error("Failed to create Gist", error)
    throw new Error("Failed to create Gist")
  }
}

// code from ./tasks/utils
const checkTokenGistScope = async (githubApiToken) => {
  const headers = {
    Authorization: `Bearer ${githubApiToken}`,
  }

  const response = await axios.get("https://api.github.com/user", { headers })

  if (response.status !== 200) {
    throw new Error(`Failed to get user data: ${response.status} ${response.statusText}`)
  }

  const scopes = response.headers["x-oauth-scopes"]?.split(", ")

  if (scopes && scopes?.[0] !== "gist") {
    throw Error("The provided Github API token does not have permissions to read and write Gists")
  }

  if (scopes && scopes.length > 1) {
    console.log("WARNING: The provided Github API token has additional permissions beyond reading and writing to Gists")
  }

  return true
}

// code from ./tasks/utils
const deleteGist = async (githubApiToken, gistURL) => {
  const headers = {
    Authorization: `Bearer ${githubApiToken}`,
  }

  const gistId = gistURL.match(/\/([a-fA-F0-9]+)$/)[1]

  try {
    const response = await axios.delete(`https://api.github.com/gists/${gistId}`, { headers })

    if (response.status !== 204) {
      throw new Error(`Failed to delete Gist: ${response.status} ${response.statusText}`)
    }

    console.log(`Off-chain secrets Gist ${gistURL} deleted successfully`)
    return true
  } catch (error) {
    console.error(`Error deleting Gist ${gistURL}`, error.response)
    return false
  }
}

function isObject(value) {
  return value !== null && typeof value === "object" && value.constructor === Object
}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error(error)
    process.exit(1)
  })

