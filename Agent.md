---

## 🛠️ Git Version Control & Branching Strategy

This repository adopts the **GitHub Flow** strategy to coordinate releases and test updates safely:

* **`main`:** Contains stable, production-ready code.
* **`development`:** Used to run, test, and polish new features before merging them into production.

### Working on Changes:
1. Make sure you are on the `development` branch to test and refine features:
   ```bash
   git checkout -b development
   ```
2. Once testing is complete and the code is verified as highly stable, merge changes back into `main` and push:
   ```bash
   git checkout main
   git merge development
   git push origin main
   ```

---