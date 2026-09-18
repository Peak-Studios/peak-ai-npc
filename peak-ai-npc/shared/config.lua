Config = {
    Debug = false,
    Diagnostics = { enabled = false }, -- Redacted lifecycle metadata only; no dialogue/audio/credentials.
    Missions = { integrations = {} }, -- Only allow trusted server resources that verify mission completion.
    Commerce = { integrations = {} }, -- Explicit resource allowlist for custom settlement drivers.
    Dispatch = {
        enabled = true,
        cooldownSeconds = 120, -- Per character, shared across NPCs and sessions.
        globalCooldownSeconds = 5, -- Server-wide burst limit, persisted on restart.
        integrations = {} -- Explicit resource allowlist; no implicit event fallback.
    },
    Medical = {
        enabled = true,
        supplies = {
            bandage = { label = 'Bandage', price = 50, maximumQuantity = 2, cooldownSeconds = 300,
                cooldownKey = 'medical:bandage', category = 'supplies', description = 'Basic first-aid supplies. Use through your installed medical system.' }
        },
        -- No direct healing/revive API is assumed. Existing medical resources
        -- own treatment; this destination guides players to their check-in.
        treatment = { provider = 'qb-ambulancejob', location = { x = 308.23, y = -595.35, z = 43.28 },
            label = 'Hospital reception', cooldownSeconds = 60 }
    },
    Police = {
        enabled = false, -- Enable only after duty, scope, and installed-system acceptance.
        records = { enabled = false, provider = 'fw-mdw' }, -- Self-service only; explicit qualification required.
        jobs = { police = true, sheriff = true, state = true, trooper = true },
        interactionDistance = 4.0,
        maximumVehicleSpeed = 0.5, -- Stop is conversational; never brakes/takes over moving traffic.
        maximumRequestsPerMinute = 30,
        exitTimeoutMs = 5000,
        integrations = {} -- Explicit server resource allowlist for respondToPoliceExit export.
    },
    ServerLore = '',
    Framework = 'qbcore',
    Inventory = 'qb-inventory',
    -- Alternate adapters (ESX, Ox/Qbox, custom) require explicit setup.
    Target = 'qb-target',

    Gateway = {
        url = nil, -- Set peak_ai_npc_gateway_url in server.cfg.
        secretConvar = 'peak_ai_npc_gateway_secret', -- Must match AI_NPC_GATEWAY_SECRET in gateway/.env
        timeoutMs = 32000,
        maxToolCallsPerTurn = 1,
        serverId = nil -- Optional server identifier for multi-server gateway deployments.
    },

    Conversations = {
        interactionPrompt = 'Press ~INPUT_CONTEXT~ to talk to %s',
        interactionPromptRefreshMs = 250,
        interactionStartTimeoutMs = 12000,
        sceneObservationRefreshMs = 1500,
        maximumDistance = 8.0,
        autoApproachDistance = 3.5,
        maxTurns = 100,
        idleTimeoutSeconds = 600,
        exclusiveByDefault = true,
        maxRequestsPerMinute = 12
    },

    Proactive = {
        enabled = true,
        includeAmbient = true,
        scanMs = 2500,
        activationDistance = 2.6,
        chancePercent = 18,
        playerCooldownSeconds = 90,
        npcCooldownSeconds = 180
    },

    Entities = {
        respawnDelayMs = 5000,
        lifecycleCheckMs = 1000
    },

    -- Ambient pedestrians can only perform these local, reversible social
    -- actions. They never inherit economy, inventory, mission, or service tools.
    Ambient = {
        enabled = true,
        interactionDistance = 3.0,
        ignoredModels = {},
        personality = 'A believable local resident. Be concise, observant, and honest about what you do not know.',
        knowledge = 'Knows only general public information, the immediate location, and supplied conversation context.',
        names = {
            'Alex Parker', 'Jordan Hayes', 'Casey Morgan', 'Taylor Brooks',
            'Jamie Rivera', 'Morgan Reed', 'Riley Bennett', 'Avery Collins',
            'Cameron Price', 'Quinn Foster', 'Drew Sullivan', 'Robin Bailey',
            'Sam Torres', 'Jesse Ward', 'Dakota Ellis', 'Skyler Monroe',
            'Reese Coleman', 'Charlie Nguyen', 'Emerson Clarke', 'Rowan Patel',
            'Hayden Murphy', 'Peyton Ross', 'Kendall James', 'Frankie Woods'
        },
        tones = { 'calm', 'friendly', 'confident', 'warm', 'reserved', 'upbeat' },
        -- Map ped model hashes/names or zone codes to authored archetypes. This
        -- avoids guessing identity from appearance while still letting a model,
        -- role and location consistently drive dialogue, mannerisms and TTS.
        archetypes = {
            civilian = { occupation = 'local resident', tone = 'grounded and conversational', deliveryPreset = 'neutral', personality = 'A practical local who speaks plainly and keeps their distance from trouble.' },
            tech = { occupation = 'tech worker', tone = 'precise, quick and mildly distracted', deliveryPreset = 'neutral', personality = 'A technically minded local who notices devices, systems and practical details.' },
            unhoused = { occupation = 'street resident', tone = 'guarded but human', deliveryPreset = 'neutral', personality = 'A resourceful local spending time outside. They protect their dignity, notice street conditions, and do not exist to be mocked or exploited.' },
            gang = { occupation = 'neighborhood crew member', tone = 'controlled, territorial and direct', deliveryPreset = 'stern', personality = 'An explicitly configured neighborhood crew member. They use short, confident street language without caricature, defend their space, and de-escalate when possible.' },
            shopkeeper = { occupation = 'shopkeeper', tone = 'warm, alert and practical', deliveryPreset = 'warm', personality = 'An experienced neighborhood shopkeeper who is welcoming to respectful customers, firm with abuse, and watchful around threats.' }
        },
        modelArchetypes = {
            [joaat('a_m_y_business_01')] = 'tech', [joaat('a_m_m_business_01')] = 'tech',
            [joaat('a_f_y_business_01')] = 'tech', [joaat('a_f_m_business_02')] = 'tech',
            [joaat('a_m_m_tramp_01')] = 'unhoused', [joaat('a_m_o_tramp_01')] = 'unhoused',
            [joaat('a_f_m_tramp_01')] = 'unhoused', [joaat('u_m_o_tramp_01')] = 'unhoused',
            [joaat('g_m_y_ballaeast_01')] = 'gang', [joaat('g_m_y_ballaorig_01')] = 'gang',
            [joaat('g_m_y_famca_01')] = 'gang', [joaat('g_m_y_famdnf_01')] = 'gang',
            [joaat('g_m_y_lost_01')] = 'gang', [joaat('g_m_y_mexgoon_02')] = 'gang',
            [joaat('mp_m_shopkeep_01')] = 'shopkeeper'
        },
        modelAgeBands = {
            [joaat('a_m_y_business_01')] = 'young adult', [joaat('a_m_m_business_01')] = 'middle-aged',
            [joaat('a_f_y_business_01')] = 'young adult', [joaat('a_f_m_business_02')] = 'middle-aged',
            [joaat('a_m_m_tramp_01')] = 'middle-aged', [joaat('a_m_o_tramp_01')] = 'older adult',
            [joaat('a_f_m_tramp_01')] = 'middle-aged', [joaat('u_m_o_tramp_01')] = 'older adult',
            [joaat('g_m_y_ballaeast_01')] = 'young adult', [joaat('g_m_y_ballaorig_01')] = 'young adult',
            [joaat('g_m_y_famca_01')] = 'young adult', [joaat('g_m_y_famdnf_01')] = 'young adult',
            [joaat('g_m_y_lost_01')] = 'young adult', [joaat('g_m_y_mexgoon_02')] = 'young adult',
            [joaat('mp_m_shopkeep_01')] = 'adult'
        },
        zoneArchetypes = {}, -- e.g. [`DAVIS`] = 'gang'
        memory = true,
        allowedTools = { 'npc_react', 'npc_follow_player', 'npc_stop', 'npc_crouch', 'npc_perform_move', 'npc_look_at', 'npc_walk_to_position' },
        maximumRoamDistance = 100.0,
        maximumObservedStep = 12.0
    },

    -- Provider-neutral identities. The gateway owns and validates the actual
    -- provider voice IDs for these profile keys.
    VoiceProfiles = {
        exclusive = { martin_hale = 'martin-hale', rico = 'rico' },
        fallbackPool = { 'ambient.neutral.01', 'ambient.neutral.02', 'ambient.neutral.03' },
        ambientPools = {
            civilian = { male = { any = { 'ambient.civilian.male.01', 'ambient.civilian.male.02', 'ambient.civilian.male.03' } }, female = { any = { 'ambient.civilian.female.01', 'ambient.civilian.female.02', 'ambient.civilian.female.03' } }, unspecified = { any = { 'ambient.neutral.01', 'ambient.neutral.02', 'ambient.neutral.03' } } },
            tech = { male = { any = { 'ambient.tech.male.01', 'ambient.tech.male.02' } }, female = { any = { 'ambient.tech.female.01', 'ambient.tech.female.02' } } },
            unhoused = { male = { any = { 'ambient.street.male.01', 'ambient.street.male.02' } }, female = { any = { 'ambient.street.female.01', 'ambient.street.female.02' } } },
            gang = { male = { any = { 'ambient.crew.male.01', 'ambient.crew.male.02' } }, female = { any = { 'ambient.crew.female.01', 'ambient.crew.female.02' } } },
            shopkeeper = { male = { any = { 'ambient.shopkeeper.male.01', 'ambient.shopkeeper.male.02' } }, female = { any = { 'ambient.shopkeeper.female.01', 'ambient.shopkeeper.female.02' } } }
        }
    },

    -- Deterministic presentation policy. The server resolves one directive from
    -- authored role/model data, server-owned world state, routine state, and
    -- bounded social treatment. Clients only render the replicated directive.
    Behavior = {
        enabled = true,
        tickMs = 5000,
        directiveRefreshMs = 15000,
        treatmentDurationMs = 6000,
        environmentCacheMs = 1000,
        populationCacheMs = 2000,
        surroundingsRadius = 30.0,
        crowdedPlayerCount = 4,
        heavyTrafficVehicleCount = 8,
        fastVehicleMetersPerSecond = 12.0,
        maximumObservedVehicles = 256,
        -- Used only when no supported server weather resource is running.
        fallbackWeather = 'UNKNOWN',
        zoneTraits = {},
        profiles = {
            civilian = {
                day = { mode = 'wander', radius = 8.0, speed = 1.0 },
                night = { mode = 'wander', radius = 4.0, speed = 0.8, facial = 'stressed' },
                trafficHeavy = { mode = 'scenario', scenario = 'WORLD_HUMAN_STAND_IMPATIENT' },
                crowded = { mode = 'scenario', scenario = 'WORLD_HUMAN_STAND_MOBILE' },
                weather = {
                    wet = { mode = 'scenario', scenario = 'WORLD_HUMAN_STAND_IMPATIENT', facial = 'stressed' },
                    cold = { mode = 'scenario', scenario = 'WORLD_HUMAN_STAND_IMPATIENT' }
                },
                activities = {
                    working = { mode = 'scenario', scenario = 'WORLD_HUMAN_CLIPBOARD' },
                    breakfast = { mode = 'scenario', scenario = 'WORLD_HUMAN_DRINKING' },
                    socializing = { mode = 'scenario', scenario = 'WORLD_HUMAN_STAND_MOBILE' },
                    sleeping = { mode = 'idle' }
                },
                reactions = {
                    respectful = { mode = 'face', facial = 'happy' },
                    insulting = { mode = 'face', facial = 'angry' },
                    threatening = { mode = 'flee', radius = 60.0, speed = 1.2, facial = 'stressed' }
                }
            },
            tech = {
                day = { mode = 'scenario', scenario = 'WORLD_HUMAN_STAND_MOBILE' },
                night = { mode = 'wander', radius = 5.0, speed = 1.1 },
                trafficHeavy = { mode = 'scenario', scenario = 'WORLD_HUMAN_STAND_MOBILE' },
                crowded = { mode = 'scenario', scenario = 'WORLD_HUMAN_STAND_MOBILE' },
                weather = {
                    wet = { mode = 'scenario', scenario = 'WORLD_HUMAN_STAND_MOBILE', facial = 'stressed' },
                    cold = { mode = 'scenario', scenario = 'WORLD_HUMAN_STAND_IMPATIENT' }
                },
                activities = {
                    working = { mode = 'scenario', scenario = 'WORLD_HUMAN_CLIPBOARD' },
                    breakfast = { mode = 'scenario', scenario = 'WORLD_HUMAN_DRINKING' },
                    socializing = { mode = 'scenario', scenario = 'WORLD_HUMAN_STAND_MOBILE' },
                    sleeping = { mode = 'idle' }
                },
                reactions = {
                    respectful = { mode = 'face', facial = 'happy' },
                    insulting = { mode = 'face', facial = 'angry' },
                    threatening = { mode = 'flee', radius = 70.0, speed = 1.35, facial = 'stressed' }
                }
            },
            unhoused = {
                day = { mode = 'wander', radius = 6.0, speed = 0.8 },
                night = { mode = 'scenario', scenario = 'PROP_HUMAN_SEAT_CHAIR_MP_PLAYER' },
                trafficHeavy = { mode = 'scenario', scenario = 'WORLD_HUMAN_STAND_IMPATIENT', facial = 'stressed' },
                crowded = { mode = 'scenario', scenario = 'WORLD_HUMAN_STAND_IMPATIENT' },
                weather = {
                    wet = { mode = 'scenario', scenario = 'WORLD_HUMAN_STAND_IMPATIENT', facial = 'stressed' },
                    cold = { mode = 'scenario', scenario = 'WORLD_HUMAN_STAND_IMPATIENT', facial = 'stressed' }
                },
                activities = {
                    working = { mode = 'wander', radius = 5.0, speed = 0.8 },
                    breakfast = { mode = 'scenario', scenario = 'WORLD_HUMAN_DRINKING' },
                    socializing = { mode = 'scenario', scenario = 'WORLD_HUMAN_STAND_MOBILE' },
                    sleeping = { mode = 'idle' }
                },
                reactions = {
                    respectful = { mode = 'face', facial = 'happy' },
                    insulting = { mode = 'face', facial = 'angry' },
                    threatening = { mode = 'retreat', radius = 25.0, speed = 1.1, facial = 'stressed' }
                }
            },
            gang = {
                day = { mode = 'scenario', scenario = 'WORLD_HUMAN_SMOKING' },
                night = { mode = 'scenario', scenario = 'WORLD_HUMAN_GUARD_STAND', facial = 'angry' },
                trafficHeavy = { mode = 'scenario', scenario = 'WORLD_HUMAN_GUARD_STAND' },
                withAllies = { mode = 'scenario', scenario = 'WORLD_HUMAN_SMOKING' },
                crowded = { mode = 'scenario', scenario = 'WORLD_HUMAN_SMOKING' },
                weather = {
                    wet = { mode = 'scenario', scenario = 'WORLD_HUMAN_GUARD_STAND' },
                    cold = { mode = 'scenario', scenario = 'WORLD_HUMAN_GUARD_STAND' }
                },
                activities = {
                    working = { mode = 'scenario', scenario = 'WORLD_HUMAN_GUARD_STAND' },
                    breakfast = { mode = 'scenario', scenario = 'WORLD_HUMAN_DRINKING' },
                    socializing = { mode = 'scenario', scenario = 'WORLD_HUMAN_SMOKING' },
                    sleeping = { mode = 'idle' }
                },
                reactions = {
                    respectful = { mode = 'face', facial = 'happy' },
                    insulting = { mode = 'face', facial = 'angry' },
                    -- Generic social behavior may stand its ground, but it never
                    -- selects combat or grants a weapon.
                    threatening = { mode = 'face', facial = 'angry' }
                }
            },
            shopkeeper = {
                indoors = true,
                day = { mode = 'scenario', scenario = 'WORLD_HUMAN_CLIPBOARD' },
                night = { mode = 'scenario', scenario = 'WORLD_HUMAN_STAND_IMPATIENT' },
                crowded = { mode = 'scenario', scenario = 'WORLD_HUMAN_CLIPBOARD' },
                activities = {
                    working = { mode = 'scenario', scenario = 'WORLD_HUMAN_CLIPBOARD' },
                    socializing = { mode = 'scenario', scenario = 'WORLD_HUMAN_STAND_MOBILE' },
                    sleeping = { mode = 'idle' }
                },
                reactions = {
                    respectful = { mode = 'face', facial = 'happy' },
                    insulting = { mode = 'face', facial = 'angry' },
                    threatening = { mode = 'surrender', facial = 'stressed' }
                }
            }
        }
    },

    ShopRobbery = {
        enabled = true,
        checkIntervalMs = 250,
        maximumDistance = 4.0,
        broadcastDistance = 80.0,
        triggerHoldMs = 900,
        cooldownSeconds = 300,
        -- Client sight/aim data only requests a reaction. The direct
        -- qb-storerobbery bridge owns cash, register state, dispatch and
        -- completion. The event below remains an audited extension hook.
        event = 'peak_ai_npc:server:shopRobberyResolved'
    },

    Residents = {
        enabled = true,
        maximumProfiles = 500,
        maximumActive = 80,
        maximumActivePerBucket = 24,
        spawnDistance = 140.0,
        despawnDistance = 200.0,
        despawnGraceSeconds = 60,
        refreshSeconds = 60,
        lifecycleCheckMs = 2000,
        recoverySeconds = 1800,
        permanentDeath = false
    },

    Security = {
        requireConfirmationForPurchases = true, -- Legacy setting; commerce always requires an explicit quote confirmation.
        maximumTransactionValue = 5000,
        auditWriteTools = true
    },

    Memory = {
        enabled = true,
        minimumImportance = 0.65,
        retentionDays = 90
    },

    VoiceInput = {
        enabled = true, -- Voice is the primary interaction; text remains available when STT is unavailable.
        language = nil, -- Optional BCP-47/ISO language hint, for example "en".
        maximumDataUrlBytes = 8000000,
        latentBytesPerSecond = 256000
    },

    Subtitles = {
        enabled = true,
        mode = 'always', -- always, never, player_preference, audio_failed, or accessibility
        audience = 'nearby', -- nearby or interacting
        playerPreferenceDefault = true,
        accessibilityDefault = false,
        showLocalPlayerTranscript = true,
        maximumDistance = 22.0,
        requireLineOfSight = true,
        headOffset = 0.42,
        charactersPerLine = 42,
        maximumLines = 4,
        minimumDurationMs = 2800,
        maximumDurationMs = 9000,
        millisecondsPerCharacter = 48,
        fadeDurationMs = 350,
        accentColor = { 184, 255, 101 }
    },

    Vision = {
        -- Per-server opt in: use `setr peak_ai_npc_vision_enabled 1` only after
        -- configuring the provider and disclosing screenshot use to players.
        enabled = GetConvarInt and GetConvarInt('peak_ai_npc_vision_enabled', 0) == 1 or false,
        automaticTurnContext = true,
        refreshSeconds = 15, -- First turn plus meaningful/aged scene changes; never a frame loop.
        captureTimeoutMs = 12000,
        screenshotBasicResource = 'screenshot-basic',
        maximumPromptLength = 500,
        encoding = 'jpg',
        quality = 0.65
    }
}
