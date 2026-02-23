open -a TextEdit README.md
```

Ça ouvre le fichier dans TextEdit. Sélectionne tout (`Cmd + A`), supprime, puis colle ce texte :
```
# RAIN Protocol

**Record of Authorship, Iterations & Narrative**

Open protocol for certifying AI-assisted creation processes.

> RAIN certifies a verifiable methodology, not a metaphysical truth.
> Its strength is making contestation possible — outside of us.

## Status

Work in progress — not production-ready.

## Verify a bundle in 3 commands

    unzip RAIN-2026-P1-0001.zip -d ./check
    cd check && bash verify.sh .
    echo $?   # 0 = VALID, 1 = INVALID, 2 = DOWNGRADE

## What RAIN proves

- That a documented creation process exists
- That the process is internally consistent
- That the documentation is timestamped and signed
- That anyone can verify the above without trusting Deluge

## What RAIN does NOT prove

- That the content is true, original, or legal
- That the creator is honest
- That the AI outputs are accurate

## License

Apache 2.0
