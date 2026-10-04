# RISKS.md

Nothing in the catalog is vetted. The catalog is a list of whatever was
published, by whoever published it, so AppGarden cannot promise that an
application is safe - it can only tell you, before you download one, that the
software sits in a category that is *known* to be abused, and why.

That is what `Resources/RiskCategories.plist` is: a list of threat categories,
the words that mean "this one", and the two sentences the panel shows. When
Get finds a word, the download waits and a panel names the category, its short
and its detailed sentence, and the keywords that fired.

## What is searched

`AGRiskAdviser` builds one list of texts per item and every category is
matched against all of it, so "any metadata" means what it says:

1. the item's name (`AnchorWallet`) and its display name (`Anchor Wallet`)
2. its summary and its full description
3. its categories, in both the feed's spelling (`AudioVideo`) and the sidebar's
   (`Audio & Video`)
4. its authors' names
5. its repository (`owner/repo`)
6. the URLs it links to

## How a keyword matches

Matching is case, accent and punctuation insensitive, and whole-word:

    AI workspace        matches the keyword "ai"
    ai-powered tools    matches the keyword "ai"
    SparkleDesk         matches the keyword "openai" (camel case is split)
    GPT4All             matches the keyword "gpt"  (digit boundaries are split)
    Aarynwood           matches the keyword "ai"
    available, e-mail,  do not match the keyword "ai"
    chair, wastewater

The whole-word rule is what makes a two-letter keyword usable at all: without
it "ai" would also fire on "available", "email" and "chair". It is also why a
keyword list cannot contain a fragment - write "wallet" for wallets, not
"wallt".

## The categories

| Identifier | What it covers |
| --- | --- |
| `ai-agents` | Assistants, agents and language models: software that reads files, runs commands and spends your tokens. |
| `wallets-crypto` | Wallets, coins and exchanges: seed phrases, clipboard swaps, no way back. |
| `remote-access` | Remote control, tunnels, port forwarding, trojans: a path from the internet into the machine. |
| `credential-access` | Password stores, keychains, API keys and authenticators: the keys to everything else. |
| `surveillance` | Screen recorders, webcams, spyware: a copy of what happens in front of you. |
| `scareware` | Antivirus, cleaners and optimizers that invent problems and sell the fix. |
| `unauthorized-modified` | Cracks, keygens, activators and repacks: binaries whose author is hiding. |
| `system-privileged` | Root, services, kernel modules: rights that reach the whole system. |
| `bulk-mailing-scraping` | Bulk senders, bots and scrapers: acts done in your name. |
| `vpn-proxy` | Proxies and VPNs: someone else in the middle of every request. |

Against the live catalog (2569 items) these fire on about 14% of it, almost
all of it AI clients and crypto wallets. The false positives that remain are
games whose computer opponent is called "AI", and an item that merely lists
"agent" in its repository name - which is why the panel shows the keywords:
a guess from a word is something to read, not a verdict.

## Editing the file

`Resources/RiskCategories.plist` ships with the app and is read once per
process. A category needs:

    Identifier      a key nothing else uses, e.g. "ai-agents"
    Title           the panel's headline for it
    ShortRisk       one sentence: what this category can do
    DetailedRisk    the longer explanation, with what to look at
    Keywords        the words, as they are written in a description

An entry missing any of those is dropped when the file is read, so a
half-written line costs the reader that one category and not the warning
itself. After editing, run the unit test (`gnustep-tests AppGarden/Tests/Unit`),
which reads the shipped file and checks that every category can say something,
that no identifier repeats, and that whole-word matching behaves.

To try a new category without editing the shipped file, point the app at a
catalog fixture whose items carry the words you want to see and click Get:

    defaults write io.github.gershwin-desktop.AppGarden AGFeedURL \
      file:///path/to/AppGarden/Fixtures/feed-risk.json

`Fixtures/feed-risk.json` is three invented items: one AI client, one wallet
and one plain editor that must raise nothing. Remove the cache directory
first (`~/Library/Caches/io.github.gershwin-desktop.AppGarden`), or the
catalog fetched six hours ago wins over the fixture.