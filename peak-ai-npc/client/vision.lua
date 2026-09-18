RegisterNetEvent(AINPC.Event.CaptureVision, function(sessionId, token, uploadUrl)
    if type(sessionId) ~= 'string' or type(token) ~= 'string' or not token:match('^[%w_-]+$') or type(uploadUrl) ~= 'string' or #uploadUrl > 2048 or not uploadUrl:match('^https?://') then return end
    -- Capture remains a background transport detail. The server receives the
    -- result and can fall back to native scene context without interrupting the
    -- conversation or exposing per-capture status in the player UI.
    if GetResourceState(Config.Vision.screenshotBasicResource) ~= 'started' then
        TriggerServerEvent(AINPC.Event.VisionUploaded, sessionId, token, false)
        return
    end
    exports[Config.Vision.screenshotBasicResource]:requestScreenshotUpload(uploadUrl, 'files[]', {
        encoding = Config.Vision.encoding or 'jpg',
        quality = tonumber(Config.Vision.quality) or 0.65
    }, function(responseBody)
        local decodedOk, response = pcall(json.decode, tostring(responseBody or ''))
        local uploaded = decodedOk and type(response) == 'table' and response.ok == true
        TriggerServerEvent(AINPC.Event.VisionUploaded, sessionId, token, uploaded)
    end)
end)
