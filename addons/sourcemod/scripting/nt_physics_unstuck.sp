#include <sourcemod>
#include <sdktools>
#include <dhooks>

#include <neotokyo>

#pragma semicolon 1

#define PLUGIN_VERSION "0.1.0"
#define DEBUG false

#define COLLISION_GROUP_NONE 0 // Default NT player non-active physics prop interaction.
#define COLLISION_GROUP_PUSHAWAY 17 // Nonsolid on client and server, pushaway in player code. This activates when a phys prop is moving around.

#define INVALID_ENTITY_HANDLE 0xFFFFFFFF
#define CHECKSTUCK_MINTIME 0.05 // Engine checkstuck min interval
#define TIMER_MAX_ACCURACY 0.1

#define TIMER_RE_ENABLE_COLLISION 1.0

#define NEO_MAX_PLAYERS 32

static int props[32];
static int head;

public Plugin myinfo = {
	name = "NT Physics Unstuck",
	description = "Temporarily toggle physics prop collision if a player is stuck inside it.",
	author = "Rain",
	version = PLUGIN_VERSION,
	url = "https://github.com/Rainyan/sourcemod-nt-physics-unstuck"
};

public void OnPluginStart()
{
	if (TIMER_RE_ENABLE_COLLISION <= CHECKSTUCK_MINTIME + TIMER_MAX_ACCURACY)
	{
		SetFailState("Re-enable collision is too fast!");
	}

	GameData gd = LoadGameConfigFile("neotokyo/physics_unstuck");
	if (!gd)
	{
		SetFailState("Failed to load GameData");
	}

	DynamicDetour dd_cr = DynamicDetour.FromConf(gd, "Fn_CollisionRulesChanged");
	if (!dd_cr)
	{
		SetFailState("Failed to create dynamic detour: Fn_CollisionRulesChanged");
	}
	if (!dd_cr.Enable(Hook_Pre, CollisionRulesChanged))
	{
		SetFailState("Failed to enable detour hook: Fn_CollisionRulesChanged");
	}

	DynamicDetour dd_cs = DynamicDetour.FromConf(gd, "Fn_CheckStuck");
	if (!dd_cs)
	{
		SetFailState("Failed to create dynamic detour: Fn_CheckStuck");
	}
	if (!dd_cs.Enable(Hook_Post, CheckStuck))
	{
		SetFailState("Failed to enable detour hook: Fn_CheckStuck");
	}

	delete gd;
}

public MRESReturn CheckStuck(Address pThis, DHookReturn hReturn, DHookParam hParams)
{
	// Someone somewhere is stuck!
	if (hReturn.Value)
	{
		float pos[3];
		// Update everyone's stuck status
		for (int client = 1; client <= MaxClients; ++client)
		{
			if (!IsClientInGame(client) || GetClientTeam(client) <= TEAM_SPECTATOR)
			{
				continue;
			}
			GetClientAbsOrigin(client, pos);
			TR_EnumerateEntitiesPoint(pos, PARTITION_SOLID_EDICTS, HitResult, client);
		}
	}
	return MRES_Ignored;
}

public bool HitResult(int entity, int client)
{
	int entref = EntIndexToEntRef(entity);
	if (entref == INVALID_ENT_REFERENCE)
	{
		return false;
	}

	for (int i = 0; i < sizeof(props); ++i)
	{
		//PrintToServer("Iterating: %d vs %d", props[i], entref);
		if (props[i] == entref && IsValidEdict(entref))
		{
			UnstuckPlayer(client, entref);
			return false;
		}
	}
	return true;
}

void UnstuckPlayer(int client, int entref)
{
	if (!IsClientInGame(client))
	{
		// Cannot safely throw because we're calling from inside
		// game physics detour and this must return control.
		LogError("Client was not in game: %d", client);
		return;
	}
	Hack_SetEntityCollisionGroup(entref, COLLISION_GROUP_PUSHAWAY);
	CreateTimer(TIMER_RE_ENABLE_COLLISION, Timer_EnableCollision, entref, TIMER_FLAG_NO_MAPCHANGE);
}

public Action Timer_EnableCollision(Handle timer, int entref)
{
	Hack_SetEntityCollisionGroup(entref, COLLISION_GROUP_NONE);
	return Plugin_Stop;
}

void Hack_SetEntityCollisionGroup(int entity_or_entref, int collision_group)
{
	// Always convert to entity index before actually passing in.
	entity_or_entref = EntRefToEntIndex(entity_or_entref);
	if (!IsValidEntity(entity_or_entref))
	{
		return;
	}

	Handle call;
	StartPrepSDKCall(SDKCall_Static);
	PrepSDKCall_SetSignature(SDKLibrary_Server, "\x8B\x0D\x2A\x2A\x2A\x2A\x8B\x01\x8B\x50\x6C\xFF\xD2\x84\xC0\x75\x2A\x83\x3D\x2A\x2A\x2A\x2A\x00\x7F\x2A", 26);
	call = EndPrepSDKCall();
#if(DEBUG)
	if (call == INVALID_HANDLE)
	{
		SetFailState("Failed to prep SDK call: PhysIsInCallback");
	}
#endif
	bool in_physics_callback = SDKCall(call);
	delete call;

	// Ensure no recursive physics callbacks
	if (in_physics_callback)
	{
#if(DEBUG)
		PrintToServer("!! In physics callback; bail out");
#endif
		return;
	}

	StartPrepSDKCall(SDKCall_Entity);
	PrepSDKCall_SetSignature(SDKLibrary_Server, "\x56\x8B\xF1\x8B\x86\xF4\x01\x00\x00", 9);
	PrepSDKCall_AddParameter(SDKType_PlainOldData, SDKPass_Plain);
	call = EndPrepSDKCall();
#if(DEBUG)
	if (call == INVALID_HANDLE)
	{
		SetFailState("Failed to prep SDK call: SetCollisionGroup");
	}
#endif
	SDKCall(call, entity_or_entref, collision_group);
	delete call;
}

static char buffer[13]; // strlen "prop_physics" + 1
public MRESReturn CollisionRulesChanged(int entity)
{
	if (!IsValidEdict(entity))
	{
		return MRES_Ignored;
	}

	if (!GetEntityClassname(entity, buffer, sizeof(buffer)))
	{
		return MRES_Ignored;
	}

	// Because our string buffer cuts off at 12+1,
	// this will match "prop_physics", and also any "prop_physics_..." derivatives.
	if (!StrEqual(buffer, "prop_physics"))
	{
		return MRES_Ignored;
	}

	int collision_group = GetEntProp(entity, Prop_Send, "m_CollisionGroup");

	// This prop just went into being non-solid for players.
	if (collision_group == COLLISION_GROUP_PUSHAWAY)
	{
		int entref = EntIndexToEntRef(entity);
		for (int i = 0; i < sizeof(props); ++i)
		{
			if (props[i] == entref)
			{
				props[i] = INVALID_ENT_REFERENCE;
				break;
			}
		}
	}
	// This prop just returned to being solid and inactive.
	else if (collision_group == COLLISION_GROUP_NONE)
	{
		props[head] = EntIndexToEntRef(entity);
		head = (head + 1) % sizeof(props);
	}

	return MRES_Ignored;
}