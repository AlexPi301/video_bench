"""URL configuration for the Video Bench backend.

The backend is intentionally integrated without application-specific endpoints yet.
"""

from django.urls import path

from .impact_cycle import (
    cancel_impact_cycle_job,
    create_impact_cycle_job,
    get_impact_cycle_activities,
    get_impact_cycle_bundle,
    get_impact_cycle_job,
    get_impact_cycle_job_events,
    list_impact_cycle_jobs,
    serve_impact_cycle_file,
    upload_impact_cycle_video,
)
from .mounted_files import list_mounted_files, save_mounted_file, serve_mounted_file


urlpatterns = [
    path("api/mounted-files/", list_mounted_files, name="mounted-files-list"),
    path("api/mounted-files/file/", serve_mounted_file, name="mounted-files-file"),
    path("api/mounted-files/save/", save_mounted_file, name="mounted-files-save"),
    path("api/impact-cycle/uploads/", upload_impact_cycle_video, name="impact-cycle-upload"),
    path("api/impact-cycle/jobs/", create_impact_cycle_job, name="impact-cycle-job-create"),
    path("api/impact-cycle/jobs/list/", list_impact_cycle_jobs, name="impact-cycle-job-list"),
    path("api/impact-cycle/jobs/<str:job_id>/", get_impact_cycle_job, name="impact-cycle-job-detail"),
    path("api/impact-cycle/jobs/<str:job_id>/events/", get_impact_cycle_job_events, name="impact-cycle-job-events"),
    path("api/impact-cycle/jobs/<str:job_id>/bundle/", get_impact_cycle_bundle, name="impact-cycle-job-bundle"),
    path("api/impact-cycle/jobs/<str:job_id>/cancel/", cancel_impact_cycle_job, name="impact-cycle-job-cancel"),
    path("api/impact-cycle/activities/", get_impact_cycle_activities, name="impact-cycle-activities"),
    path("api/impact-cycle/file/", serve_impact_cycle_file, name="impact-cycle-file"),
]
