#include <sourcemod>
#include <sdktools>
#include <dhooks>

#include <neotokyo>

#pragma semicolon 1

#define PLUGIN_VERSION "0.6.4"
#define DEBUG false

#define COLLISION_GROUP_NONE 0 // Default NT player non-active physics prop interaction.
#define COLLISION_GROUP_PUSHAWAY 17 // Nonsolid on client and server, pushaway in player code. This activates when a phys prop is moving around.

#define CHECKSTUCK_MINTIME 0.05 // Engine checkstuck min interval
#define TIMER_MAX_ACCURACY 0.1

#define TIMER_RE_ENABLE_COLLISION 1.5

#define NEO_MAX_PLAYERS 32

static int _player_being_processed = INVALID_ENT_REFERENCE;
static int props[32];
static int head;

static float mins[3] = { -16.0, -16.0, 0.0 };
static float maxs[3] = { 16.0, 16.0, 70.0 };

static Handle call_PhysIsInCallback = INVALID_HANDLE;
static Handle call_SetCollisionGroup = INVALID_HANDLE;

public Plugin myinfo = {
	name = "NT Physics Unstuck",
	description = "Temporarily toggle physics prop collision if a player is stuck inside it.",
	author = "Rain",
	version = PLUGIN_VERSION,
	url = "https://github.com/Rainyan/sourcemod-nt-physics-unstuck"
};

public void OnPluginStart()
{
	StartPrepSDKCall(SDKCall_Static);
	PrepSDKCall_SetSignature(SDKLibrary_Server, "\x8B\x0D\x2A\x2A\x2A\x2A\x8B\x01\x8B\x50\x6C\xFF\xD2\x84\xC0\x75\x2A\x83\x3D\x2A\x2A\x2A\x2A\x00\x7F\x2A", 26);
	call_PhysIsInCallback = EndPrepSDKCall();
	if (call_PhysIsInCallback == INVALID_HANDLE)
	{
		SetFailState("Failed to prep SDK call");
	}

	StartPrepSDKCall(SDKCall_Entity);
	PrepSDKCall_SetSignature(SDKLibrary_Server, "\x56\x8B\xF1\x8B\x86\xF4\x01\x00\x00", 9);
	PrepSDKCall_AddParameter(SDKType_PlainOldData, SDKPass_Plain);
	call_SetCollisionGroup = EndPrepSDKCall();
	if (call_SetCollisionGroup == INVALID_HANDLE)
	{
		SetFailState("Failed to prep SDK call");
	}

	if (TIMER_RE_ENABLE_COLLISION <= CHECKSTUCK_MINTIME + TIMER_MAX_ACCURACY)
	{
		SetFailState("Re-enable collision is too fast!");
	}

	GameData gd = LoadGameConfigFile("neotokyo/physics_unstuck");
	if (!gd)
	{
		SetFailState("Failed to load GameData");
	}

	DynamicDetour dd = DynamicDetour.FromConf(gd, "Fn_CollisionRulesChanged");
	if (!dd)
	{
		SetFailState("Failed to create dynamic detour: Fn_CollisionRulesChanged");
	}
	if (!dd.Enable(Hook_Pre, CollisionRulesChanged))
	{
		SetFailState("Failed to enable detour hook: Fn_CollisionRulesChanged");
	}
	delete dd;

	dd = DynamicDetour.FromConf(gd, "Fn_CheckStuck");
	if (!dd)
	{
		SetFailState("Failed to create dynamic detour: Fn_CheckStuck");
	}
	if (!dd.Enable(Hook_Post, CheckStuck))
	{
		SetFailState("Failed to detour: Fn_CheckStuck");
	}
	delete dd;

	dd = DynamicDetour.FromConf(gd, "Fn_ProcessMovement");
	if (!dd)
	{
		SetFailState("Failed to create dynamic detour: Fn_ProcessMovement");
	}
	if (!dd.Enable(Hook_Pre, ProcessMovement))
	{
		SetFailState("Failed to detour: Fn_ProcessMovement");
	}
	delete dd;

	dd = DynamicDetour.FromConf(gd, "Fn_CPhysicsProp__VPhysicsCollision");
	if (!dd)
	{
		SetFailState("Failed to create dynamic detour: Fn_CPhysicsProp__VPhysicsCollision");
	}
	if (!dd.Enable(Hook_Pre, VPhysicsCollision))
	{
		SetFailState("Failed to detour: Fn_CPhysicsProp__VPhysicsCollision");
	}
	delete dd;

	dd = DynamicDetour.FromConf(gd, "Fn_CPhysicsProp__OnTakeDamage");
	if (!dd)
	{
		SetFailState("Failed to create dynamic detour: Fn_CPhysicsProp__OnTakeDamage");
	}
	if (!dd.Enable(Hook_Post, OnTakeDamage))
	{
		SetFailState("Failed to detour: Fn_CPhysicsProp__OnTakeDamage");
	}
	delete dd;

	delete gd;
}

#if(DEBUG)
float lastCheck = 0.0;
#endif
public MRESReturn CheckStuck(Address pThis, DHookReturn hReturn)
{
#if(DEBUG)
	float time = GetGameTime();
	PrintToServer("CheckStuck dt: %f", time - lastCheck);
	lastCheck = time;
#endif

	// Someone somewhere is stuck!
	if (hReturn.Value)
	{
		if (!IsValidEdict(_player_being_processed) ||
			!IsClientInGame(_player_being_processed) ||
			GetClientTeam(_player_being_processed) <= TEAM_SPECTATOR)
		{
			return MRES_Ignored;
		}

		float pos[3];
		GetClientAbsOrigin(_player_being_processed, pos);
		TR_EnumerateEntitiesHull(pos, pos, mins, maxs, PARTITION_SOLID_EDICTS,
			HitResult, _player_being_processed);
	}
	return MRES_Ignored;
}

public MRESReturn ProcessMovement(Address pThis, DHookParam hParams)
{
	_player_being_processed = hParams.Get(1);
	return MRES_Ignored;
}

public bool HitResult(int entity, int client)
{
	if (entity == client)
	{
		return true;
	}

	int entref = EntIndexToEntRef(entity);
	if (entref == INVALID_ENT_REFERENCE)
	{
		return true;
	}

	for (int i = 0; i < sizeof(props); ++i)
	{
		//PrintToServer("Iterating: %d vs %d", props[i], entref);
		if (props[i] == entref && IsValidEdict(entref))
		{
#if(DEBUG)
			PrintToChat(client, "UNSTUCK!");
#endif
			UnstuckPlayer(client, entref);
			return false;
		}
	}
	return true;
}

void UnstuckPlayer(int client, int entity_or_entref)
{
	if (!IsClientInGame(client))
	{
		LogError("Client was not in game: %d", client);
		return;
	}
	Hack_SetEntityCollisionGroup(entity_or_entref, COLLISION_GROUP_PUSHAWAY);
	CreateTimer(TIMER_RE_ENABLE_COLLISION, Timer_EnableCollision,
		entity_or_entref, TIMER_FLAG_NO_MAPCHANGE);
}

public Action Timer_EnableCollision(Handle timer, int entref)
{
	Hack_SetEntityCollisionGroup(entref, COLLISION_GROUP_NONE);
	return Plugin_Stop;
}

// SM has a function for this, but we don't have mod compatibility
// because of some missing offsets. Calling directly, for now.
void Hack_SetEntityCollisionGroup(int entity_or_entref, int collision_group)
{
	if (!IsValidEntity(entity_or_entref))
	{
		return;
	}

	if (SDKCall(call_PhysIsInCallback))
	{
		return;
	}

	SDKCall(call_SetCollisionGroup, entity_or_entref, collision_group);
}

public Action Timer_RemoveFromProps(Handle timer, int entref)
{
	for (int i = 0; i < sizeof(props); ++i)
	{
		if (props[i] == entref)
		{
			props[i] = INVALID_ENT_REFERENCE;
			break;
		}
	}
	return Plugin_Stop;
}

MRESReturn InferredPhysicsPropMovement(int entity)
{
	if (!IsValidEdict(entity))
	{
		return MRES_Ignored;
	}

	if (GetEntityMoveType(entity) != MOVETYPE_VPHYSICS)
	{
		return MRES_Ignored;
	}

	// one more than strlen("prop_physics") + 1,
	// because we only want exact match; not any prop_physics_... variants
	char buffer[12 + 1 + 1];
	if (!GetEntityClassname(entity, buffer, sizeof(buffer)))
	{
		return MRES_Ignored;
	}

	if (!StrEqual(buffer, "prop_physics"))
	{
		return MRES_Ignored;
	}

#if(DEBUG)
	if (!HasEntProp(entity, Prop_Send, "m_CollisionGroup"))
	{
		LogError("Entity %d of class %s has no sendprop \"m_CollisionGroup\"",
			entity, buffer);
		return MRES_Ignored;
	}
#endif

	int entref = EntIndexToEntRef(entity);
	for (int i = 0; i < sizeof(props); ++i)
	{
		if (props[i] == entref)
		{
			return MRES_Ignored;
		}
	}
	props[head] = EntIndexToEntRef(entity);
	head = (head + 1) % sizeof(props);

	CreateTimer(1.0, Timer_RemoveFromProps, entref);

	return MRES_Ignored;
}

public MRESReturn OnTakeDamage(int entity, DHookReturn hReturn, DHookParam hParams)
{
	return InferredPhysicsPropMovement(entity);
}

public MRESReturn VPhysicsCollision(int entity, DHookParam hParams)
{
	return InferredPhysicsPropMovement(entity);
}

static char buffer[12 + 1]; // strlen "prop_physics" + 1
public MRESReturn CollisionRulesChanged(int entity)
{
	if (!IsValidEdict(entity))
	{
		return MRES_Ignored;
	}

	if (GetEntityMoveType(entity) != MOVETYPE_VPHYSICS)
	{
		return MRES_Ignored;
	}

	if (!GetEntityClassname(entity, buffer, sizeof(buffer)))
	{
		return MRES_Ignored;
	}

	// Because our string buffer cuts off at 12+1,
	// this will match "prop_physics", and also any "prop_physics_..." derivatives.
	if (!StrEqual(buffer, "prop_physics") &&
		!StrEqual(buffer, "func_physbox"))
	{
		return MRES_Ignored;
	}


#if(DEBUG)
	if (!HasEntProp(entity, Prop_Send, "m_CollisionGroup"))
	{
		LogError("Entity %d of class %s has no sendprop \"m_CollisionGroup\"",
			entity, buffer);
		return MRES_Ignored;
	}
#endif
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