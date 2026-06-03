// Command kustomize-overlay-diff renders every kustomize overlay on a base tree
// and on a head tree, then writes a Markdown report of the overlays whose
// rendered output changed. It is a Go port of kustomize-overlay-diff.sh and
// produces byte-for-byte the same report.
//
// An "overlay" is any directory that is an immediate child of a directory named
// "overlays" and that contains a kustomization.yaml. Rendering the full overlay
// (rather than diffing changed files) means transitive changes — e.g. an edit
// to a shared base/ or components/ dir — show up against every overlay they
// affect.
//
// Diffs are produced with dyff, which compares the manifests semantically:
// resources are matched by kind/name/namespace, so document reordering and key
// ordering never show up as spurious changes. dyff cannot compare streams with
// a differing document count when it can't key the documents (notably a set of
// same-kind resources, or one side rendering empty); those cases fall back to a
// plain `diff -u` so a real change is never silently dropped.
//
// Usage: kustomize-overlay-diff <base-tree> <head-tree> <output.md>
//
// Run directly with `go run .` or build a static binary with `go build`. It
// shells out to kustomize, dyff and diff, which must be on PATH.
package main

import (
	"bytes"
	"errors"
	"fmt"
	"io/fs"
	"os"
	"os/exec"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
)

const marker = "<!-- kustomize-overlay-diff -->"

func main() {
	prog := filepath.Base(os.Args[0])
	args := os.Args[1:]

	// Show full help on request, before any argument validation.
	if len(args) > 0 && (args[0] == "-h" || args[0] == "--help") {
		fmt.Fprint(os.Stdout, usage(prog))
		os.Exit(0)
	}

	if len(args) != 3 {
		fmt.Fprintf(os.Stderr, "%s: error: expected 3 arguments, got %d.\n\n", prog, len(args))
		fmt.Fprint(os.Stderr, usage(prog))
		os.Exit(2)
	}

	cfg := config{
		baseDir:      args[0],
		headDir:      args[1],
		out:          args[2],
		maxDiffLines: maxDiffLinesFromEnv(),
	}

	if err := run(cfg); err != nil {
		fmt.Fprintf(os.Stderr, "%s: error: %v\n", prog, err)
		os.Exit(1)
	}
}

type config struct {
	baseDir      string
	headDir      string
	out          string
	maxDiffLines int
}

// maxDiffLinesFromEnv mirrors MAX_DIFF_LINES from the shell script (default 400).
func maxDiffLinesFromEnv() int {
	if v := os.Getenv("MAX_DIFF_LINES"); v != "" {
		if n, err := strconv.Atoi(v); err == nil && n > 0 {
			return n
		}
	}
	return 400
}

func usage(prog string) string {
	return fmt.Sprintf(`Usage: %s <base-tree> <head-tree> <output.md>

Render every kustomize overlay found in each tree and write a Markdown report
of the overlays whose rendered output differs between them.

Arguments:
  base-tree    Path to the checkout to compare against (e.g. the target branch).
  head-tree    Path to the checkout under review (e.g. the PR head).
  output.md    File to write the Markdown report to (overwritten if it exists).

Environment:
  MAX_DIFF_LINES   Truncate each overlay's diff block to this many lines
                   (default: 400) to stay under GitHub's comment size limit.

Requires kustomize and dyff on PATH.
`, prog)
}

func run(cfg config) error {
	for _, bin := range []string{"kustomize", "dyff"} {
		if _, err := exec.LookPath(bin); err != nil {
			return fmt.Errorf("%q not found on PATH", bin)
		}
	}

	workdir, err := os.MkdirTemp("", "kustomize-overlay-diff-")
	if err != nil {
		return err
	}
	defer os.RemoveAll(workdir)

	overlays, err := unionOverlays(cfg.baseDir, cfg.headDir)
	if err != nil {
		return err
	}

	var (
		summaryRows []string // rows for the summary table
		changed     []string // markdown blocks, one per changed overlay
	)

	baseOut := filepath.Join(workdir, "base.yaml")
	headOut := filepath.Join(workdir, "head.yaml")

	for _, overlay := range overlays {
		basePresent := fileExists(filepath.Join(cfg.baseDir, overlay, "kustomization.yaml"))
		headPresent := fileExists(filepath.Join(cfg.headDir, overlay, "kustomization.yaml"))

		var (
			baseStdout, headStdout []byte
			headStderr             []byte
			headRC                 int
		)
		if basePresent {
			baseStdout, _, _ = kustomizeBuild(cfg.baseDir, overlay)
		}
		if headPresent {
			headStdout, headStderr, headRC = kustomizeBuild(cfg.headDir, overlay)
		}

		// A build error on the PR head is always worth reporting, loudly.
		if headPresent && headRC != 0 {
			summaryRows = append(summaryRows, fmt.Sprintf("| `%s` | 🛑 build failed |", overlay))
			changed = append(changed, block(true, "🛑", overlay, "kustomize build failed", "", string(headStderr)))
			continue
		}

		var icon, label, fence, body string
		switch {
		case !basePresent && headPresent:
			icon, label, fence = "🟢", "new overlay", "yaml"
			body = truncateBlock(string(headStdout), cfg.maxDiffLines)
		case basePresent && !headPresent:
			icon, label, fence = "🔴", "overlay removed", "yaml"
			body = truncateBlock(string(baseStdout), cfg.maxDiffLines)
		default:
			// Both present (base build failures are surfaced inside the diff).
			if err := os.WriteFile(baseOut, baseStdout, 0o644); err != nil {
				return err
			}
			if err := os.WriteFile(headOut, headStdout, 0o644); err != nil {
				return err
			}
			dyffOut, dyffRC := dyffBetween(baseOut, headOut)
			switch dyffRC {
			case 0:
				continue // semantically identical — nothing to report
			case 1:
				icon, label, fence = "🟡", "modified", "diff"
				body = truncateBlock(string(dyffOut), cfg.maxDiffLines)
			default:
				// dyff couldn't compare — fall back to a textual diff.
				icon, label, fence = "🟡", "modified (textual diff — dyff unavailable)", "diff"
				body = truncateBlock(unifiedDiff(baseOut, headOut, overlay), cfg.maxDiffLines)
			}
		}

		summaryRows = append(summaryRows, fmt.Sprintf("| `%s` | %s %s |", overlay, icon, label))
		changed = append(changed, block(false, icon, overlay, label, fence, body))
	}

	report := assembleReport(len(overlays), summaryRows, changed)
	if err := os.WriteFile(cfg.out, []byte(report), 0o644); err != nil {
		return err
	}

	fmt.Printf("Wrote report for %d overlay(s), %d changed, to %s\n", len(overlays), len(changed), cfg.out)
	return nil
}

// unionOverlays returns the sorted union of overlay paths present on either tree.
func unionOverlays(baseDir, headDir string) ([]string, error) {
	seen := map[string]struct{}{}
	for _, root := range []string{baseDir, headDir} {
		found, err := listOverlays(root)
		if err != nil {
			return nil, err
		}
		for _, o := range found {
			seen[o] = struct{}{}
		}
	}
	overlays := make([]string, 0, len(seen))
	for o := range seen {
		overlays = append(overlays, o)
	}
	sort.Strings(overlays)
	return overlays, nil
}

// listOverlays returns the relative paths of directories that are an immediate
// child of an "overlays" directory and contain a kustomization.yaml.
func listOverlays(root string) ([]string, error) {
	if !dirExists(root) {
		return nil, nil
	}
	var overlays []string
	err := filepath.WalkDir(root, func(path string, d fs.DirEntry, err error) error {
		if err != nil {
			return nil // tolerate unreadable subtrees, like the shell's 2>/dev/null
		}
		if !d.IsDir() || filepath.Base(filepath.Dir(path)) != "overlays" {
			return nil
		}
		if !fileExists(filepath.Join(path, "kustomization.yaml")) {
			return nil
		}
		rel, err := filepath.Rel(root, path)
		if err != nil {
			return err
		}
		overlays = append(overlays, filepath.ToSlash(rel))
		return nil
	})
	return overlays, err
}

// kustomizeBuild renders an overlay, returning stdout, stderr and the exit code.
func kustomizeBuild(root, overlay string) (stdout, stderr []byte, code int) {
	return capture("kustomize", "build", filepath.Join(root, overlay))
}

// dyffBetween runs a semantic diff, returning the github-styled output and the
// exit code (0 identical, 1 differences, anything else a dyff error).
func dyffBetween(baseFile, headFile string) (out []byte, code int) {
	out, _, code = capture("dyff", "between", "--set-exit-code", "--omit-header", "--output", "github", baseFile, headFile)
	return out, code
}

// unifiedDiff is the textual fallback used when dyff cannot compare the inputs.
func unifiedDiff(baseFile, headFile, overlay string) string {
	out, _, _ := capture("diff", "-u", baseFile, headFile, "--label", "a/"+overlay, "--label", "b/"+overlay)
	return string(out)
}

// capture runs a command and returns its stdout, stderr and exit code. A
// non-zero exit (the command ran but failed) is reported via code, not an error.
func capture(name string, args ...string) (stdout, stderr []byte, code int) {
	cmd := exec.Command(name, args...)
	var so, se bytes.Buffer
	cmd.Stdout = &so
	cmd.Stderr = &se
	err := cmd.Run()
	if err != nil {
		var ee *exec.ExitError
		if errors.As(err, &ee) {
			code = ee.ExitCode()
		} else {
			code = -1
		}
	}
	return so.Bytes(), se.Bytes(), code
}

// truncateBlock clips text to max lines, appending a note if it was clipped.
// It mirrors the shell's `wc -l` / `head -n` behaviour (lines == newlines).
func truncateBlock(s string, max int) string {
	total := strings.Count(s, "\n")
	if total <= max {
		return s
	}
	idx := 0
	for i := 0; i < max; i++ {
		j := strings.IndexByte(s[idx:], '\n')
		if j < 0 {
			idx = len(s)
			break
		}
		idx += j + 1
	}
	return s[:idx] + fmt.Sprintf("\n... truncated (%d lines total) — render locally with `kustomize build`.\n", total)
}

// block renders one collapsible <details> section for an overlay. Trailing
// newlines are trimmed from the body to match the shell, where the body is
// captured through `$(...)` command substitution before being formatted.
func block(open bool, icon, overlay, label, fence, body string) string {
	tag := "<details>"
	if open {
		tag = "<details open>"
	}
	body = strings.TrimRight(body, "\n")
	return fmt.Sprintf("%s<summary>%s <code>%s</code> — %s</summary>\n\n```%s\n%s\n```\n\n</details>",
		tag, icon, overlay, label, fence, body)
}

// assembleReport builds the full Markdown report.
func assembleReport(total int, summaryRows, changed []string) string {
	var b strings.Builder
	b.WriteString(marker + "\n")
	b.WriteString("## 🧬 Kustomize overlay diff\n")
	b.WriteString("\n")

	if len(changed) == 0 {
		b.WriteString("✅ No rendered changes in any kustomize overlay.\n")
		b.WriteString("\n")
		fmt.Fprintf(&b, "_Compared %d overlay(s) against the base branch with dyff._\n", total)
		return b.String()
	}

	fmt.Fprintf(&b, "%d of %d overlay(s) changed:\n\n", len(changed), total)
	b.WriteString("| Overlay | Status |\n")
	b.WriteString("| --- | --- |\n")
	for _, row := range summaryRows {
		b.WriteString(row + "\n")
	}
	b.WriteString("\n")
	for _, blk := range changed {
		b.WriteString(blk + "\n\n")
	}
	return b.String()
}

func fileExists(path string) bool {
	info, err := os.Stat(path)
	return err == nil && !info.IsDir()
}

func dirExists(path string) bool {
	info, err := os.Stat(path)
	return err == nil && info.IsDir()
}
