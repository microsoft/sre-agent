export default function Billing() {
  return (
    <div className="billing-page">
      <h1>Billing &amp; Payments</h1>
      <p className="subtitle">Account #: 4400-7821-0033</p>

      <div className="cards">
        <div className="card card-info">
          <div className="card-value">$142.37</div>
          <div className="card-label">Current Balance</div>
        </div>
        <div className="card card-success">
          <div className="card-value">$128.50</div>
          <div className="card-label">Last Payment</div>
          <div className="card-detail">Paid Dec 18, 2024</div>
        </div>
        <div className="card card-warning">
          <div className="card-value">Feb 1, 2025</div>
          <div className="card-label">Next Due Date</div>
        </div>
      </div>

      <h2>Recent Statements</h2>
      <div className="table-wrap">
        <table className="outage-table">
          <thead>
            <tr>
              <th>Period</th>
              <th>Usage (kWh)</th>
              <th>Amount</th>
              <th>Status</th>
            </tr>
          </thead>
          <tbody>
            <tr>
              <td>Dec 2024</td>
              <td className="num">890</td>
              <td className="num">$142.37</td>
              <td><span className="badge badge-warning">Due</span></td>
            </tr>
            <tr>
              <td>Nov 2024</td>
              <td className="num">710</td>
              <td className="num">$128.50</td>
              <td><span className="badge badge-success">Paid</span></td>
            </tr>
            <tr>
              <td>Oct 2024</td>
              <td className="num">640</td>
              <td className="num">$115.20</td>
              <td><span className="badge badge-success">Paid</span></td>
            </tr>
            <tr>
              <td>Sep 2024</td>
              <td className="num">870</td>
              <td className="num">$139.80</td>
              <td><span className="badge badge-success">Paid</span></td>
            </tr>
          </tbody>
        </table>
      </div>

      <div className="billing-actions">
        <button className="btn btn-primary">Pay Now</button>
        <button className="btn btn-secondary">Set Up AutoPay</button>
        <button className="btn btn-secondary">Download Statement</button>
      </div>
    </div>
  );
}
