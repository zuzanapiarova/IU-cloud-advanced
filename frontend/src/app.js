import './styles.css'

const form = document.getElementById('transaction-form')
const resultDiv = document.getElementById('result')

form.addEventListener('submit', async (event) => {
    event.preventDefault()

    const name = document.getElementById('name').value
    const balance = parseFloat(document.getElementById('balance').value)
    const outgoing = parseFloat(document.getElementById('outgoing').value)
    const incoming = parseFloat(document.getElementById('incoming').value)

    try {
        const params = new URLSearchParams({
            name,
            balance: String(balance),
            outgoing: String(outgoing),
            incoming: String(incoming)
          });
      
        const response = await fetch(`/api/process_payment?${params.toString()}`) // same domain, no need to input api url
        
        if (response.ok) {
            const data = await response.json()
            resultDiv.innerText = `New Balance: ${data.result}`
        } else {
            const errorData = await response.json()
            resultDiv.innerText = `Error: ${errorData.message}`
        }
    }
    catch (err) {
        // network error, backend not running, CORS issues, etc.
        resultDiv.innerText = 'Error: Unable to reach backend service.'
        console.error('Request failed:', err)
    }
});