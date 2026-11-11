# waggle.so

Static site: home (`index.html`), the essay (`decision-requests/`) the install guide (`install/`) and the download page (`download/`).

Deploy (Vercel project "waggle"): from this folder run `vercel deploy --prod`. The folder must be linked once with `vercel link` (it writes `.vercel/`, which git ignores).

Tracking: every page loads Vercel Web Analytics (`/_vercel/insights/script.js`, page views only, no cookies). Turn it on once for the project in the Vercel dashboard. Download buttons open `download/`, which starts the DMG; its page views are the download count. A new page needs the same two script lines before `</head>`.
