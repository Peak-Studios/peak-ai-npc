-- Manual, local-only discovery. Does not spawn, stream, mutate or upload peds.
local running = false
RegisterCommand('ainpc_ped_catalog', function(_, args)
    if running then return end
    local page = tonumber(args[1] or '1')
    if not page or page % 1 ~= 0 or page < 1 then
        print('[peak-ai-npc] Usage: ainpc_ped_catalog [page] (50 models per page)')
        return
    end
    running = true
    CreateThread(function()
        local ok = pcall(function()
            local names = {}
            for model in pairs(AINPCPedCatalog.models) do names[#names + 1] = model end
            table.sort(names)
            local pages = math.ceil(#names / 50)
            if page > pages then
                print(('[peak-ai-npc] Catalog has %d pages.'):format(pages))
                return
            end
            local report = {
                version = AINPCPedCatalog.version,
                sourceRevision = AINPCPedCatalog.sourceRevision,
                build = GetGameBuildNumber(), targetBuild = AINPCPedCatalog.targetBuild,
                completeForBuild = false, page = page, pages = pages, models = {}
            }
            for index = (page - 1) * 50 + 1, math.min(page * 50, #names) do
                local model = names[index]
                local hash = joaat(model)
                local available = IsModelInCdimage(hash) and IsModelValid(hash) and IsModelAPed(hash)
                report.models[#report.models + 1] = {
                    model = model, available = available,
                    classification = available and AINPCPedCatalog.models[model] or 'unavailable',
                    image = 'https://docs.fivem.net/peds/' .. model .. '.webp',
                    visualReview = 'pending', voiceReview = 'pending'
                }
                if index % 10 == 0 then Wait(0) end
            end
            -- One bounded JSON line per command can be saved from the local F8 log.
            print('[peak-ai-npc:ped-catalog] ' .. json.encode(report))
        end)
        running = false
        if not ok then print('[peak-ai-npc] Ped catalog probe failed; no availability claim was saved.') end
    end)
end, false)
