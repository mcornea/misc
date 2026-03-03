package main

import (
	"encoding/csv"
	"fmt"
	"io"
	"os"
	"strconv"
	"strings"

	"github.com/go-echarts/go-echarts/v2/charts"
	"github.com/go-echarts/go-echarts/v2/components"
	"github.com/go-echarts/go-echarts/v2/opts"
)

type metricsRow struct {
	Timestamp    string
	RSSBytes     float64
	DBTotalBytes float64
	DBInUseBytes float64
	EventsTotal  float64
	WatcherTotal float64
	Phase        string
}

func loadMetricsCSV(filename string) ([]metricsRow, error) {
	f, err := os.Open(filename)
	if err != nil {
		return nil, fmt.Errorf("failed to open %s: %w", filename, err)
	}
	defer f.Close()

	reader := csv.NewReader(f)
	reader.FieldsPerRecord = -1 // tolerate corrupted rows (partial writes)
	// Skip header
	if _, err := reader.Read(); err != nil {
		return nil, fmt.Errorf("failed to read header: %w", err)
	}

	var rows []metricsRow
	for {
		record, err := reader.Read()
		if err == io.EOF {
			break
		}
		if err != nil {
			return nil, fmt.Errorf("failed to read row: %w", err)
		}
		if len(record) < 7 {
			continue
		}

		rss, _ := strconv.ParseFloat(record[1], 64)
		dbTotal, _ := strconv.ParseFloat(record[2], 64)
		dbInUse, _ := strconv.ParseFloat(record[3], 64)
		events, _ := strconv.ParseFloat(record[4], 64)
		watchers, _ := strconv.ParseFloat(record[5], 64)

		rows = append(rows, metricsRow{
			Timestamp:    record[0],
			RSSBytes:     rss,
			DBTotalBytes: dbTotal,
			DBInUseBytes: dbInUse,
			EventsTotal:  events,
			WatcherTotal: watchers,
			Phase:        record[6],
		})
	}
	return rows, nil
}

func generateCharts(csvFiles []string, legends []string, outFile string) error {
	allData := make([][]metricsRow, len(csvFiles))
	for i, f := range csvFiles {
		rows, err := loadMetricsCSV(f)
		if err != nil {
			return err
		}
		allData[i] = rows
	}

	page := components.NewPage()
	page.SetLayout(components.PageFlexLayout)

	// Chart 1: RSS Memory over time
	rssChart := charts.NewLine()
	rssChart.SetGlobalOptions(
		charts.WithInitializationOpts(opts.Initialization{Width: "900px", Height: "400px"}),
		charts.WithTitleOpts(opts.Title{Title: "RSS Memory Over Time"}),
		charts.WithYAxisOpts(opts.YAxis{Name: "MiB"}),
		charts.WithXAxisOpts(opts.XAxis{Name: "Time"}),
		charts.WithTooltipOpts(opts.Tooltip{Show: boolPtr(true)}),
		charts.WithLegendOpts(opts.Legend{Show: boolPtr(true)}),
		charts.WithToolboxOpts(opts.Toolbox{
			Show: boolPtr(true),
			Feature: &opts.ToolBoxFeature{
				SaveAsImage: &opts.ToolBoxFeatureSaveAsImage{Show: boolPtr(true), Title: "Save"},
				DataView:    &opts.ToolBoxFeatureDataView{Show: boolPtr(true), Title: "Data", Lang: []string{"Data view", "Close", "Refresh"}},
			},
		}),
	)

	for i, rows := range allData {
		xAxis := make([]string, len(rows))
		lineData := make([]opts.LineData, len(rows))
		for j, r := range rows {
			// Shorten timestamp for display
			ts := r.Timestamp
			if len(ts) > 19 {
				ts = ts[11:19]
			}
			xAxis[j] = ts
			lineData[j] = opts.LineData{Value: r.RSSBytes / 1024 / 1024}
		}
		if i == 0 {
			rssChart.SetXAxis(xAxis)
		}
		rssChart.AddSeries(legends[i], lineData)
	}
	page.AddCharts(rssChart)

	// Write HTML
	f, err := os.Create(outFile)
	if err != nil {
		return fmt.Errorf("failed to create output file %s: %w", outFile, err)
	}
	defer f.Close()

	if err := page.Render(io.MultiWriter(f)); err != nil {
		return fmt.Errorf("failed to render page: %w", err)
	}
	fmt.Printf("Chart saved to %s\n", outFile)
	return nil
}

func boolPtr(v bool) *bool {
	return &v
}

// parsePlotArgs parses the -plot flag value into csv files list
func parsePlotArgs(plotFlag string) []string {
	return strings.Split(plotFlag, ",")
}

// parseLegendArgs parses the -legend flag value into legend names
func parseLegendArgs(legendFlag string, numFiles int) []string {
	if legendFlag != "" {
		return strings.Split(legendFlag, ",")
	}
	legends := make([]string, numFiles)
	for i := range legends {
		legends[i] = fmt.Sprintf("run-%d", i+1)
	}
	return legends
}
