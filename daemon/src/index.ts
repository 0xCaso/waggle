import { main } from "./cli";

process.exit(await main(process.argv.slice(2)));
