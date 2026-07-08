package com.otterworks.report.controller;

import com.otterworks.report.service.ReportDataFetcher;
import com.otterworks.report.util.ReportDateUtils;
import io.swagger.annotations.Api;
import io.swagger.annotations.ApiOperation;
import io.swagger.annotations.ApiParam;
import io.swagger.annotations.ApiResponse;
import io.swagger.annotations.ApiResponses;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.http.ResponseEntity;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RequestParam;
import org.springframework.web.bind.annotation.RestController;

import java.util.Date;
import java.util.HashMap;
import java.util.List;
import java.util.Map;

/**
 * Dashboard endpoint for aggregated usage metrics.
 *
 * Provides pre-computed summary statistics consumed by the admin dashboard
 * and executive reporting views. Data is sourced from the same user-activity
 * pipeline used by the report generators.
 */
@RestController
@RequestMapping("/api/v1/usage-summary")
@Api(tags = "Usage Summary", description = "Aggregated usage metrics for dashboards")
public class UsageSummaryController {

    private static final Logger logger = LoggerFactory.getLogger(UsageSummaryController.class);

    private final ReportDataFetcher dataFetcher;

    public UsageSummaryController(ReportDataFetcher dataFetcher) {
        this.dataFetcher = dataFetcher;
    }

    @GetMapping
    @ApiOperation(value = "Get aggregated usage summary",
            notes = "Computes storage and activity totals from user activity data. "
                    + "Used by the admin dashboard for at-a-glance metrics.")
    @ApiResponses({
            @ApiResponse(code = 200, message = "Aggregated summary"),
            @ApiResponse(code = 500, message = "Internal error computing summary")
    })
    public ResponseEntity<Map<String, Object>> getUsageSummary(
            @ApiParam(value = "Start date (ISO 8601)")
            @RequestParam(required = false) String from,
            @ApiParam(value = "End date (ISO 8601)")
            @RequestParam(required = false) String to) {

        Date dateFrom = (from != null) ? ReportDateUtils.parseIsoDate(from)
                : ReportDateUtils.daysAgo(30);
        Date dateTo = (to != null) ? ReportDateUtils.parseIsoDate(to)
                : new Date();

        logger.info("Computing usage summary for period {} to {}",
                ReportDateUtils.toIsoString(dateFrom), ReportDateUtils.toIsoString(dateTo));

        List<Map<String, Object>> activityData = dataFetcher.fetchUserActivityData(dateFrom, dateTo, null);

        // Aggregate metrics across all user records
        long totalStorageMb = 0;
        long totalFilesUploaded = 0;
        long totalDocsCreated = 0;
        int activeUserCount = 0;

        for (Map<String, Object> record : activityData) {
            totalStorageMb += ((Number) record.get("storage_used_mb")).longValue();
            totalFilesUploaded += ((Number) record.get("files_uploaded")).longValue();
            totalDocsCreated += ((Number) record.get("docs_created")).longValue();

            Object active = record.get("active");
            if (Boolean.TRUE.equals(active)) {
                activeUserCount++;
            }
        }

        Map<String, Object> summary = new HashMap<>();
        summary.put("total_storage_mb", totalStorageMb);
        summary.put("total_files_uploaded", totalFilesUploaded);
        summary.put("total_docs_created", totalDocsCreated);
        summary.put("active_users", activeUserCount);
        summary.put("total_users", activityData.size());
        summary.put("period_from", ReportDateUtils.toIsoString(dateFrom));
        summary.put("period_to", ReportDateUtils.toIsoString(dateTo));

        logger.info("Usage summary: {} users, {} MB storage, {} files, {} docs",
                activityData.size(), totalStorageMb, totalFilesUploaded, totalDocsCreated);

        return ResponseEntity.ok(summary);
    }
}
